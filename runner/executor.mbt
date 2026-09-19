///|
async fn validate_options(
  assignment : @protocol.Assignment,
  options : Options,
) -> Options {
  guard assignment.version == @protocol.version &&
    assignment.state == "leased" &&
    assignment.has_valid_numbers() &&
    assignment.job.steps.length() > 0 &&
    assignment.job.steps.length() <= 64 else {
    raise InvalidConfiguration("runner requires a fresh leased assignment")
  }
  guard assignment.job.timeout_minutes >= 1 &&
    assignment.job.timeout_minutes <= 360 &&
    options.heartbeat_ms >= 50 &&
    options.heartbeat_ms <= 10000 else {
    raise InvalidConfiguration("invalid job timeout or heartbeat interval")
  }
  guard monotonic_ms() >= 0L &&
    prepare_agent(if options.unsafe_local { 1 } else { 0 }) == 0 else {
    raise InvalidConfiguration(
      "runner must be non-root PID 1 in an isolated Linux container; --unsafe-local is for trusted tests only",
    )
  }
  let workspace = @fs.realpath(options.workspace)
  guard @fs.kind(workspace) is Directory && @fs.readdir(workspace).is_empty() else {
    raise InvalidConfiguration("workspace must be an empty directory")
  }
  let launcher = @fs.realpath(options.launcher)
  guard @fs.kind(launcher) is Regular && @fs.can_execute(launcher) else {
    raise InvalidConfiguration("step launcher is not executable")
  }
  let ids : Map[String, Bool] = Map([])
  for step in assignment.job.steps {
    guard !step.id.is_empty() &&
      !ids.contains(step.id) &&
      ["", "sh", "bash"].contains(step.shell) &&
      !step.run.contains("\u{0000}") &&
      !step.run.contains("${{") &&
      step.timeout_minutes >= 0 &&
      step.timeout_minutes <= 360 &&
      @utf8.encode(step.run).length() <= 65536 else {
      raise InvalidConfiguration("invalid step plan")
    }
    ids[step.id] = true
    for name, value in step.env {
      guard !name.is_empty() &&
        name
        .iter()
        .all(ch => ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_') &&
        name.get_char(0) is Some(first) &&
        (first.is_ascii_alphabetic() || first == '_') &&
        !name.has_prefix("MOONHUB_") &&
        !name.has_prefix("GITHUB_") &&
        !name.has_prefix("RUNNER_") &&
        !name.has_prefix("LD_") &&
        !name.has_prefix("DYLD_") &&
        !["BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS"].contains(name) &&
        !value.contains("\u{0000}") else {
        raise InvalidConfiguration(
          "step contains a reserved or unsafe environment variable",
        )
      }
    }
  }
  { ..options, workspace, launcher, }
}

///|
async fn step_directory(workspace : String, relative : String) -> String {
  guard !relative.is_empty() &&
    relative.length() <= 512 &&
    relative.iter().all(ch => ch.to_int() >= 32 && ch.to_int() != 127) &&
    !relative.has_prefix("/") &&
    !relative.contains("\\") &&
    !relative.contains(":") &&
    relative.split("/").all(part => !part.is_empty() && part != "..") else {
    raise InvalidConfiguration("working directory escapes workspace")
  }
  let cwd = @fs.realpath(workspace + "/" + relative)
  guard (cwd == workspace || cwd.has_prefix(workspace + "/")) &&
    @fs.kind(cwd) is Directory else {
    raise InvalidConfiguration("working directory escapes workspace")
  }
  cwd
}

///|
async fn Runtime::step_state(
  self : Runtime,
  index : Int,
  state : String,
  code : Int,
) -> Unit {
  let step = self.assignment.job.steps[index]
  self.steps[index] = { step_id: step.id, state, exit_code: code, }
  let request : @protocol.StepRequest = {
    version: @protocol.version,
    step_id: step.id,
    state,
    exit_code: code,
  }
  ignore(self.request("steps", ToJson::to_json(request)))
}

///|
async fn Runtime::execute_script(
  self : Runtime,
  step : @protocol.StepPlan,
  script : String,
  timeout_ms : Int,
) -> Int {
  let cwd = step_directory(self.options.workspace, step.working_directory)
  let env : Map[String, String] = {
    "PATH": "/opt/moon/bin:/usr/local/bin:/usr/bin:/bin",
    "HOME": self.options.workspace + "/.home",
    "TMPDIR": self.options.workspace + "/.tmp",
    "MOON_HOME": self.options.workspace + "/.home/.moon",
    "LANG": "C.UTF-8",
    "CI": "true",
  }
  for key, value in step.env {
    env[key] = value
  }
  env["GITHUB_WORKSPACE"] = self.options.workspace
  env["GITHUB_SHA"] = self.assignment.commit_sha
  env["GITHUB_REPOSITORY"] = self.assignment.repository
  @async.with_timeout(
    timeout_ms,
    () => {
      @async.with_task_group(group => {
        let (out, out_writer) = @process.read_from_process()
        defer out.close()
        let (err, err_writer) = @process.read_from_process()
        defer err.close()
        let input = @process.redirect_from_file("/dev/null")
        let process = @process.spawn(
          group,
          self.options.launcher,
          [step.shell, script],
          inherit_env=false,
          extra_env=env,
          stdin=input,
          stdout=out_writer,
          stderr=err_writer,
          cwd~,
          cancel_handler=@process.CancellationHandler(pid => kill_group(pid)),
        )
        self.groups.push(process.pid)
        let drain_until = Ref(0L)
        let stdout = group.spawn(() => {
          self.stream_log(out, step.id, "stdout", drain_until)
        })
        let stderr = group.spawn(() => {
          self.stream_log(err, step.id, "stderr", drain_until)
        })
        let code = process.wait()
        drain_until.val = monotonic_ms() + 250L
        stdout.wait()
        stderr.wait()
        code
      })
    },
    error=Stopped("timed_out"),
  )
}

///|
async fn Runtime::execute_steps(self : Runtime, scratch : String) -> String {
  for index, step in self.assignment.job.steps {
    self.check_live()
    self.step_state(index, "running", 0)
    self.check_live()
    let script = "\{scratch}/step-\{index}.sh"
    let code = try {
      @fs.write_file(script, step.run, create_mode=CreateNew, permission=0o600)
      let remaining = self.deadline - monotonic_ms()
      guard remaining > 0L else { raise Stopped("timed_out") }
      let timeout = if step.timeout_minutes > 0 {
        Int64::min(remaining, step.timeout_minutes.to_int64() * 60000L)
      } else {
        remaining
      }
      self.execute_script(
        step,
        script,
        Int64::min(timeout, 2147483647L).to_int(),
      )
    } catch {
      err if @async.is_cancellation_error(err) => raise err
      Stopped(reason) => raise Stopped(reason)
      TransportFailure | Rejected(_) | InvalidResponse => raise Stopped("lost")
      _ => {
        self.upload(
          step.id,
          "stderr",
          "runner: could not prepare or start step\n",
        )
        1
      }
    }
    self.step_state(index, if code == 0 { "success" } else { "failure" }, code)
    if code != 0 {
      return "failure"
    }
  }
  "success"
}

///|
async fn Runtime::monitor(self : Runtime) -> String {
  let mut next = monotonic_ms() + self.options.heartbeat_ms.to_int64()
  for ;; {
    self.check_live() catch {
      Stopped(reason) => {
        self.stopped = reason
        return reason
      }
      err => raise err
    }
    if monotonic_ms() >= next {
      let request : @protocol.VersionRequest = { version: @protocol.version, }
      // The independent timeout below prevents a stalled heartbeat from extending execution.
      let remaining = Int64::min(self.lease_until, self.deadline) -
        monotonic_ms()
      let status = @async.with_timeout(Int64::max(1L, remaining).to_int(), () => {
        self.request("heartbeat", ToJson::to_json(request))
      }) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => {
          self.stopped = if monotonic_ms() >= self.deadline {
            "timed_out"
          } else {
            "lost"
          }
          return self.stopped
        }
      }
      if status.state != "running" {
        self.stopped = "lost"
      }
      next = monotonic_ms() + self.options.heartbeat_ms.to_int64()
    }
    @async.sleep(50)
  }
}

///|
async fn Runtime::cleanup_processes(self : Runtime) -> Unit {
  for pid in self.groups {
    kill_group(pid)
  }
  if !self.options.unsafe_local {
    kill_namespace()
    for retry = 0; retry < 100; retry = retry + 1 {
      if reap_namespace() == 0 {
        return
      }
      @async.sleep(10)
    }
    raise Stopped("lost")
  }
}

///|
async fn extract_source(workspace : String, archive : String) -> Unit {
  let code = @process.run(
    "tar",
    ["-xkf", archive, "-C", workspace, "--no-same-owner"],
    inherit_env=false,
    extra_env={ "PATH": "/usr/bin:/bin" },
  ) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => 125
  }
  guard code == 0 else { raise Stopped("failure") }
}

///|
async fn execute_assignment(
  assignment : @protocol.Assignment,
  options : Options,
  post : async (String, Json, Int64) -> (@protocol.LeaseState, Int64),
  source? : async () -> Bytes,
) -> Report {
  let options = validate_options(assignment, options)
  let scratch = @fs.tmpdir(prefix="moonhub-runner-")
  defer (@async.protect_from_cancel(() => @fs.rmdir(scratch, recursive=true)) catch {
    _ => ()
  })
  let runtime : Runtime = {
    post,
    execution_id: execution_nonce(),
    assignment,
    options,
    lock: @async.Mutex(),
    steps: assignment.job.steps.map(step => {
      step_id: step.id,
      state: "pending",
      exit_code: 0,
    }),
    groups: [],
    sequence: 0L,
    bytes: 0L,
    lease_until: monotonic_ms() + 15000L,
    deadline: monotonic_ms() +
    assignment.job.timeout_minutes.to_int64() * 60000L,
    stopped: "",
    reporting_until: 0L,
  }
  let mut interrupted : Error? = None
  let outcome = try {
    let request : @protocol.StartRequest = {
      version: @protocol.version,
      execution_id: runtime.execution_id,
    }
    let state = runtime.request("start", ToJson::to_json(request))
    guard state.state == "running" || state.cancel_requested else {
      raise Stopped("lost")
    }
    guard parse_runner_int64(state.log_sequence) == 0L else {
      raise Stopped("lost")
    }
    runtime.check_live()
    @fs.mkdir(options.workspace + "/.home", permission=0o700)
    @fs.mkdir(options.workspace + "/.tmp", permission=0o700)
    let moon_home = options.workspace + "/.home/.moon"
    @fs.mkdir(moon_home, permission=0o700)
    for directory in ["bin", "lib", "include"] {
      let installed = "/opt/moon/" + directory
      if @fs.exists(installed) {
        @fs.symlink(target=installed, moon_home + "/" + directory)
      }
    }
    @async.any([
      () => {
        if source is Some(fetch) {
          try {
            let archive = @async.with_timeout(30000, fetch)
            runtime.check_live()
            let archive_path = scratch + "/source.tar"
            @fs.write_file(archive_path, archive, permission=0o600)
            extract_source(options.workspace, archive_path)
          } catch {
            err if @async.is_cancellation_error(err) => raise err
            _ => {
              runtime.upload("", "stderr", "runner: source checkout failed\n")
              raise Stopped("failure")
            }
          }
        }
        runtime.check_live()
        runtime.execute_steps(scratch)
      },
      () => runtime.monitor(),
    ])
  } catch {
    err if @async.is_cancellation_error(err) => {
      interrupted = Some(err)
      "cancelled"
    }
    Stopped(reason) => reason
    _ => "lost"
  }
  let report = @async.protect_from_cancel(() => {
    let outcome = try {
      runtime.cleanup_processes()
      outcome
    } catch {
      _ => "lost"
    }
    for i, step in runtime.steps {
      if step.state == "running" {
        runtime.steps[i] = { ..step, state: outcome, exit_code: -1, }
      } else if step.state == "pending" {
        runtime.steps[i] = { ..step, state: "skipped", }
      }
    }
    if outcome == "lost" {
      return { conclusion: outcome, reported: false, steps: runtime.steps, }
    }
    // Metadata/completion are safe to replay; scripts never are. Allow a short
    // final reporting window without keeping any execution processes alive.
    runtime.reporting_until = monotonic_ms() + 3000L
    for step in runtime.steps {
      if step.state != "success" {
        let request : @protocol.StepRequest = {
          version: @protocol.version,
          step_id: step.step_id,
          state: step.state,
          exit_code: step.exit_code,
        }
        ignore(runtime.request("steps", ToJson::to_json(request))) catch {
          _ => ()
        }
      }
    }
    let request : @protocol.CompleteRequest = {
      version: @protocol.version,
      conclusion: outcome,
      last_log_sequence: runtime.sequence.to_string(),
    }
    let state = Some(runtime.request("complete", ToJson::to_json(request))) catch {
      _ => None
    }
    match state {
      Some(state) if state.state == "completed" =>
        { conclusion: state.conclusion, reported: true, steps: runtime.steps, }
      _ => { conclusion: outcome, reported: false, steps: runtime.steps, }
    }
  })
  if interrupted is Some(err) {
    raise err
  }
  report
}

///|
pub async fn run(
  assignment : @protocol.Assignment,
  token : String,
  options : Options,
) -> Report {
  guard token.length() == 64 &&
    token.iter().all(ch => ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f')) else {
    raise InvalidConfiguration("invalid attempt credential")
  }
  validate_server(options.server, options.allow_http)
  let attempt_id = assignment.attempt_id
  let post = (operation, body, until) => {
    post_retry(options.server, attempt_id, token, operation, body, until)
  }
  execute_assignment(assignment, options, post, source=() => {
    fetch_source(options.server, attempt_id, token)
  })
}
