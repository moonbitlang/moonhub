///|
async fn validate_options(
  assignment : @protocol.Assignment,
  options : Options,
) -> Options {
  guard [
      @protocol.version, @protocol.action_assignment_version, @protocol.toolchain_assignment_version,
      @protocol.secret_assignment_version, @protocol.remote_assignment_version, @protocol.scheduling_assignment_version,
      @protocol.dataflow_assignment_version, @protocol.dispatch_assignment_version,
      @protocol.variable_assignment_version, @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
    ].contains(assignment.version) &&
    assignment.state == "leased" &&
    (
      @platform.job_os(assignment.job.runs_on) == @platform.os() ||
      options.unsafe_local
    ) &&
    assignment.has_valid_numbers() &&
    assignment.job.steps.length() > 0 &&
    assignment.job.steps.length() <= 64 else {
    raise InvalidConfiguration("runner requires a fresh leased assignment")
  }
  guard !assignment.job.id_token_write ||
    [
      @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
    ].contains(assignment.version) else {
    raise InvalidConfiguration("OIDC permissions require assignment version 10")
  }
  guard !assignment.job.runs_on.contains("windows-2025") ||
    assignment.version == @protocol.environment_assignment_version else {
    raise InvalidConfiguration("Windows 2025 requires assignment version 11")
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
      "runner requires an isolated non-administrator container; --unsafe-local is for trusted tests only",
    )
  }
  check_runner_environment(assignment.job.runs_on)
  let workspace = @fs.realpath(options.workspace)
  guard @fs.kind(workspace) is Directory && @fs.readdir(workspace).is_empty() else {
    raise InvalidConfiguration("workspace must be an empty directory")
  }
  let launcher = @fs.realpath(options.launcher)
  guard @fs.kind(launcher) is Regular && @fs.can_execute(launcher) else {
    raise InvalidConfiguration("step launcher is not executable")
  }
  guard (assignment.job.matrix.is_empty() && assignment.job.strategy.is_empty()) ||
    [
      @protocol.scheduling_assignment_version, @protocol.dataflow_assignment_version,
      @protocol.dispatch_assignment_version, @protocol.variable_assignment_version,
      @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
    ].contains(assignment.version) else {
    raise InvalidConfiguration("matrix contexts require assignment version 6")
  }
  guard (assignment.job.outputs.is_empty() && assignment.job.needs.is_empty()) ||
    [
      @protocol.dataflow_assignment_version, @protocol.dispatch_assignment_version,
      @protocol.variable_assignment_version, @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
    ].contains(assignment.version) else {
    raise InvalidConfiguration("job dataflow requires assignment version 7")
  }
  guard assignment.job.outputs.length() <= 100 &&
    assignment.job.needs.length() <= 16 &&
    @utf8.encode(ToJson::to_json(assignment.job.outputs).stringify()).length() <=
    65536 &&
    @utf8.encode(ToJson::to_json(assignment.job.needs).stringify()).length() <=
    270336 else {
    raise InvalidConfiguration("job dataflow exceeds limits")
  }
  guard (
      assignment.job.dispatch_inputs.is_empty() &&
      assignment.job.event.is_empty()
    ) ||
    [
      @protocol.dispatch_assignment_version, @protocol.variable_assignment_version,
      @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
    ].contains(assignment.version) else {
    raise InvalidConfiguration("dispatch context requires assignment version 8")
  }
  guard assignment.job.dispatch_inputs.length() <= 25 &&
    assignment.job.dispatch_inputs
    .values()
    .all(value => {
      match value {
        String(text) => !text.contains("\u{0000}")
        True | False => true
        Number(value, ..) => !value.is_nan() && !value.is_inf()
        _ => false
      }
    }) &&
    @utf8.encode(ToJson::to_json(assignment.job.dispatch_inputs).stringify()).length() <=
    65535 &&
    @utf8.encode(ToJson::to_json(assignment.job.event).stringify()).length() <=
    196608 else {
    raise InvalidConfiguration("dispatch context exceeds limits")
  }
  guard assignment.job.variables.is_empty() ||
    [
      @protocol.variable_assignment_version, @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
    ].contains(assignment.version) else {
    raise InvalidConfiguration(
      "repository variables require assignment version 9",
    )
  }
  guard assignment.job.variables.length() <= 500 &&
    @utf8.encode(ToJson::to_json(assignment.job.variables).stringify()).length() <=
    262144 &&
    assignment.job.variables
    .iter()
    .all(entry => {
      let name = entry.0
      !name.is_empty() &&
      name.length() <= 100 &&
      name.get_char(0) is Some(first) &&
      (first.is_ascii_alphabetic() || first == '_') &&
      name
      .iter()
      .all(ch => ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_') &&
      name == name.to_upper() &&
      !["__PROTO__", "PROTOTYPE", "CONSTRUCTOR"].contains(name) &&
      !["GITHUB_", "MOONHUB_", "RUNNER_"].any(prefix => name.has_prefix(prefix)) &&
      !entry.1.contains("\u{0000}") &&
      @utf8.encode(entry.1).length() <= 49152
    }) else {
    raise InvalidConfiguration("invalid or oversized repository variables")
  }
  let ids : Map[String, Bool] = Map([])
  let mut checkouts = 0
  for step in assignment.job.steps {
    if !step.remote &&
      ["actions/checkout@v4", "moonhub/checkout@v1"].contains(step.uses) {
      checkouts += 1
    }
    if step.remote {
      guard @protocol.action_runtime_version(assignment.version) else {
        raise InvalidConfiguration(
          "remote actions require assignment version 5",
        )
      }
      ignore(
        @actions.parse_reference(step.uses) catch {
          _ => raise InvalidConfiguration("invalid remote action reference")
        },
      )
    }
    guard step.inputs.length() <= 100 &&
      !step.id.is_empty() &&
      !ids.contains(step.id) &&
      (
        ["", "sh", "bash"].contains(step.shell) ||
        (@platform.windows() && step.shell == "pwsh")
      ) &&
      !step.run.contains("\u{0000}") &&
      (
        !step.run.contains("${{") ||
        (
          @protocol.action_runtime_version(assignment.version) &&
          step.templates.get("run") == Some(step.run)
        )
      ) &&
      (if step.uses.is_empty() {
        !step.run.trim().is_empty() &&
        step.moonbit_version.is_empty() &&
        step.inputs.is_empty()
      } else if step.remote {
        step.run.is_empty() &&
        step.shell.is_empty() &&
        step.working_directory == "." &&
        step.moonbit_version.is_empty() &&
        step.inputs
        .iter()
        .all(entry => {
          @actions.valid_input_name(entry.0) &&
          !entry.1.contains("\u{0000}") &&
          @utf8.encode(entry.1).length() <= 65536
        })
      } else {
        step.inputs.is_empty() &&
        step.run.is_empty() &&
        step.shell.is_empty() &&
        step.working_directory == "." &&
        step.env.is_empty() &&
        step.secret_env.is_empty() &&
        (if step.uses == "moonhub/setup-moonbit@v1" {
          [
            @protocol.toolchain_assignment_version, @protocol.secret_assignment_version,
            @protocol.remote_assignment_version, @protocol.scheduling_assignment_version,
            @protocol.dataflow_assignment_version, @protocol.dispatch_assignment_version,
            @protocol.variable_assignment_version, @protocol.oidc_assignment_version,
            @protocol.environment_assignment_version,
          ].contains(assignment.version) &&
          valid_moonbit_version(step.moonbit_version)
        } else {
          ["actions/checkout@v4", "moonhub/checkout@v1"].contains(step.uses) &&
          [
            @protocol.action_assignment_version, @protocol.toolchain_assignment_version,
            @protocol.secret_assignment_version, @protocol.remote_assignment_version,
            @protocol.scheduling_assignment_version, @protocol.dataflow_assignment_version,
            @protocol.dispatch_assignment_version, @protocol.variable_assignment_version,
            @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
          ].contains(assignment.version) &&
          step.moonbit_version.is_empty() &&
          checkouts == 1
        })
      }) &&
      step.timeout_minutes >= 0 &&
      step.timeout_minutes <= 360 &&
      @utf8.encode(step.run).length() <= 65536 else {
      raise InvalidConfiguration("invalid step plan")
    }
    guard step.templates.is_empty() ||
      @protocol.action_runtime_version(assignment.version) else {
      raise InvalidConfiguration("step templates require assignment version 5")
    }
    guard step.templates.length() <= 202 &&
      step.templates
      .iter()
      .all(entry => {
        let (key, value) = entry
        !value.contains("\u{0000}") &&
        @utf8.encode(value).length() <= 65536 &&
        (
          key == "run" ||
          key == "if" ||
          key == "continue-on-error" ||
          (
            key.strip_prefix("env:") is Some(name) &&
            valid_secret_env_name(name.to_owned()) &&
            !step.env.contains(name.to_owned()) &&
            !step.secret_env.contains(name.to_owned())
          ) ||
          (
            step.remote &&
            key.strip_prefix("with:") is Some(name) &&
            @actions.valid_input_name(name.to_owned()) &&
            step.inputs.contains(name.to_owned()) &&
            !step.secret_env.contains(@actions.input_env(name.to_owned()))
          )
        )
      }) else {
      raise InvalidConfiguration("invalid step template")
    }
    ids[step.id] = true
    guard step.secret_env.is_empty() ||
      [
        @protocol.secret_assignment_version, @protocol.remote_assignment_version,
        @protocol.scheduling_assignment_version, @protocol.dataflow_assignment_version,
        @protocol.dispatch_assignment_version, @protocol.variable_assignment_version,
        @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
      ].contains(assignment.version) else {
      raise InvalidConfiguration("secret steps require assignment version 4")
    }
    guard step.env_overrides.length() <= 100 &&
      step.env_overrides.all(name => valid_secret_env_name(name)) &&
      step.env.length() + step.secret_env.length() <= 300 else {
      raise InvalidConfiguration("too many step environment variables")
    }
    for name, secret in step.secret_env {
      guard !step.env.contains(name) &&
        (
          valid_secret_env_name(name) ||
          (
            step.remote &&
            name.strip_prefix("INPUT_") is Some(input) &&
            @actions.valid_input_name(input.to_owned())
          )
        ) &&
        !secret.is_empty() &&
        secret.length() <= 100 &&
        secret.get_char(0) is Some(first) &&
        (first.is_ascii_alphabetic() || first == '_') &&
        secret
        .iter()
        .all(ch => ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_') &&
        secret == secret.to_upper() &&
        !["GITHUB_", "MOONHUB_", "RUNNER_"].any(prefix => {
          secret.has_prefix(prefix)
        }) else {
        raise InvalidConfiguration("invalid secret environment reference")
      }
    }
    for name, value in step.env {
      guard !name.is_empty() &&
        name
        .iter()
        .all(ch => ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_') &&
        name.get_char(0) is Some(first) &&
        (first.is_ascii_alphabetic() || first == '_') &&
        !name.to_upper().has_prefix("MOONHUB_") &&
        !name.to_upper().has_prefix("GITHUB_") &&
        !name.to_upper().has_prefix("RUNNER_") &&
        !name.to_upper().has_prefix("LD_") &&
        !name.to_upper().has_prefix("DYLD_") &&
        ![
          "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "NODE_OPTIONS", "ACTIONS_RUNTIME_TOKEN",
          "ACTIONS_RESULTS_URL", "ACTIONS_RUNTIME_URL", "ACTIONS_CACHE_URL", "ACTIONS_CACHE_SERVICE_V2",
          "ACTIONS_CACHE_MODE", "ACTIONS_ID_TOKEN_REQUEST_URL", "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
        ].contains(name.to_upper()) &&
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
  guard relative.length() <= 512 && @platform.valid_relative(relative) else {
    raise InvalidConfiguration("working directory escapes workspace")
  }
  let cwd = @fs.realpath(workspace + "/" + relative)
  guard @platform.within(workspace, cwd) && @fs.kind(cwd) is Directory else {
    raise InvalidConfiguration("working directory escapes workspace")
  }
  cwd
}

///|
async fn Runtime::step_state(
  self : Runtime,
  index : Int32,
  state : String,
  code : Int32,
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
  timeout_ms : Int32,
  secrets~ : Map[String, String] = Map([]),
) -> Int32 {
  let cwd = step_directory(self.options.workspace, step.working_directory)
  let env = @platform.environment()
  let job_env : Map[String, String] = {
    "PATH": "/opt/moon/bin:/usr/local/bin:/usr/bin:/bin",
    "HOME": self.job_home,
    "TMPDIR": self.action_temp,
    "MOON_HOME": self.job_home + "/.moon",
    "LANG": "C.UTF-8",
    "CI": "true",
    "RUNNER_OS": if @platform.windows() {
      "Windows"
    } else if @platform.macos() {
      "macOS"
    } else {
      "Linux"
    },
    "RUNNER_TEMP": self.action_temp,
  }
  if @platform.macos() {
    job_env["PATH"] = "/opt/moon/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  }
  if @platform.windows() {
    job_env["PATH"] = "C:/moonhub/bin;C:/moonhub/pwsh;C:/moonhub/git/cmd;C:/moonhub/git/usr/bin;" +
      env.get("PATH").unwrap_or("C:/Windows/System32;C:/Windows")
    job_env["PROCESSOR_ARCHITECTURE"] = "AMD64"
    job_env["USERPROFILE"] = self.job_home
    job_env["APPDATA"] = self.job_home + "/AppData/Roaming"
    job_env["LOCALAPPDATA"] = self.job_home + "/AppData/Local"
    job_env["TEMP"] = self.action_temp
    job_env["TMP"] = self.action_temp
  }
  for key, value in job_env {
    env[if @platform.windows() { key.to_upper() } else { key }] = value
  }
  for key, value in step.env {
    env[if @platform.windows() { key.to_upper() } else { key }] = value
  }
  for key, value in secrets {
    env[if @platform.windows() { key.to_upper() } else { key }] = value
  }
  if !self.moon_home.is_empty() && step.uses.is_empty() {
    env["MOON_HOME"] = self.moon_home
    env["PATH"] = self.moon_home +
      (if @platform.windows() { "/bin;" } else { "/bin:" }) +
      env.get("PATH").unwrap_or("/usr/local/bin:/usr/bin:/bin")
  }
  env["GITHUB_WORKSPACE"] = self.options.workspace
  env["GITHUB_SHA"] = self.assignment.commit_sha
  env["GITHUB_REPOSITORY"] = self.assignment.repository
  let script = if @platform.windows() &&
    (step.shell.is_empty() || step.shell == "pwsh") {
    let filename = script + ".ps1"
    @fs.write_file(
      filename,
      "$ErrorActionPreference = 'Stop'\n$ProgressPreference = 'SilentlyContinue'\n" +
      @fs.read_file(script).text() +
      "\nif (Test-Path variable:LASTEXITCODE) { exit $LASTEXITCODE }\n",
      permission=0o600,
    )
    filename
  } else {
    script
  }
  @async.with_timeout(
    timeout_ms,
    () => {
      // Keep pipe handles alive until every reader has left the task group.
      // Closing a Windows handle during task unwinding removes it from IOCP
      // before a pending reader receives its completion notification.
      let (out, out_writer) = @process.read_from_process()
      defer out.close()
      let (err, err_writer) = @process.read_from_process()
      defer err.close()
      let (input, gate) = if @platform.windows() {
        let (reader, writer) = @process.write_to_process()
        (reader, Some(writer))
      } else {
        (@process.redirect_from_file("/dev/null"), None)
      }
      defer (if gate is Some(writer) { writer.close() })
      let retained = Ref(0L)
      defer release_step(retained.val)
      @async.with_task_group(group => {
        // EOF also releases a launcher if spawn/retention fails before startup.
        errdefer (if gate is Some(writer) { writer.close() })
        let process = @process.spawn(
          group,
          self.options.launcher,
          if @platform.windows() {
            [step.shell, script, "--wait-for-agent"]
          } else {
            [step.shell, script]
          },
          inherit_env=false,
          extra_env=env,
          stdin=input,
          stdout=out_writer,
          stderr=err_writer,
          cwd~,
          cancel_handler=@process.CancellationHandler(pid => {
            if @platform.windows() {
              if retained.val == 0L {
                retained.val = retain_step(pid)
              }
              stop_step(retained.val)
              if gate is Some(writer) {
                writer.close()
              }
            } else {
              kill_group(pid)
            }
          }),
        )
        // The body is unwound before the task group joins its children. Stop
        // the Windows tree here, so cancelled pipe/wait tasks can finish even
        // when cancellation came from a deadline, log limit or host signal.
        errdefer (if @platform.windows() { stop_step(retained.val) })
        if @platform.windows() {
          if retained.val == 0L {
            retained.val = retain_step(process.pid)
          }
          guard retained.val != 0L else {
            raise InvalidConfiguration("cannot retain step cancellation handle")
          }
          if gate is Some(writer) {
            writer.write(b"\x01")
            writer.close()
          }
        } else {
          self.groups.push(process.pid)
        }
        let drain_until = Ref(0L)
        let stdout = group.spawn(() => {
          if @platform.windows() {
            @async.protect_from_cancel(() => {
              self.stream_log(out, step.id, "stdout", drain_until)
            })
          } else {
            self.stream_log(out, step.id, "stdout", drain_until)
          }
        })
        let stderr = group.spawn(() => {
          if @platform.windows() {
            @async.protect_from_cancel(() => {
              self.stream_log(err, step.id, "stderr", drain_until)
            })
          } else {
            self.stream_log(err, step.id, "stderr", drain_until)
          }
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
async fn Runtime::execute_steps(
  self : Runtime,
  scratch : String,
  source : (async () -> Bytes)?,
  moonbit_installer : async () -> Bytes,
) -> String {
  let mut failed = false
  for index, step in self.assignment.job.steps {
    self.check_live()
    self.step_state(index, "running", 0)
    self.check_live()
    let script = "\{scratch}/step-\{index}.sh"
    if failed &&
      @protocol.action_runtime_version(self.assignment.version) &&
      !step.remote &&
      !step.uses.is_empty() {
      self.step_state(index, "skipped", 0)
      continue
    }
    let code = try {
      let remaining = self.deadline - monotonic_ms()
      guard remaining > 0L else { raise Stopped("timed_out") }
      let timeout = if step.timeout_minutes > 0 {
        Int64::min(remaining, step.timeout_minutes.to_int64() * 60000L)
      } else {
        remaining
      }
      if step.uses == "moonhub/setup-moonbit@v1" {
        @async.with_timeout(
          Int64::min(timeout, 2147483647L).to_int(),
          () => {
            self.setup_moonbit(
              step,
              index,
              scratch,
              moonbit_installer,
              Int64::min(timeout, 2147483647L).to_int(),
            )
          },
          error=Stopped("timed_out"),
        )
      } else if !step.remote && !step.uses.is_empty() {
        guard self.assignment.job.contents_read else {
          raise InvalidConfiguration("job permissions deny contents access")
        }
        @async.with_timeout(
          Int64::min(timeout, 30000L).to_int(),
          () => self.checkout(scratch, source),
          error=Stopped("timed_out"),
        )
        self.upload(
          step.id,
          "stdout",
          "Checked out pinned source " + self.assignment.commit_sha + "\n",
        )
        0
      } else {
        let fetching_started = monotonic_ms()
        let secrets = if step.secret_env.is_empty() {
          Map([])
        } else {
          let response = @async.with_timeout(
            Int64::min(timeout, 2147483647L).to_int(),
            () => {
              (self.secrets)({
                version: @protocol.version,
                execution_id: self.execution_id,
                step_id: step.id,
              })
            },
            error=Stopped("timed_out"),
          ) catch {
            Rejected(code) if [400, 403, 404, 409].contains(code) => {
              self.upload(
                step.id,
                "stderr",
                "runner: repository secret access denied\n",
              )
              raise InvalidConfiguration("repository secret access denied")
            }
            err => raise err
          }
          guard response.version == @protocol.version &&
            response.env.length() == step.secret_env.length() &&
            response.env
            .iter()
            .all(entry => {
              step.secret_env.contains(entry.0) &&
              !entry.1.contains("\u{0000}") &&
              @utf8.encode(entry.1).length() <= 16384
            }) else {
            raise InvalidResponse
          }
          self.check_live()
          response.env
        }
        let script_timeout = timeout - (monotonic_ms() - fetching_started)
        guard script_timeout > 0L else { raise Stopped("timed_out") }
        if @protocol.action_runtime_version(self.assignment.version) {
          self.execute_action_step(
            step,
            index,
            scratch,
            Int64::min(script_timeout, 2147483647L).to_int(),
            secrets,
            failed,
          )
        } else {
          @fs.write_file(
            script,
            step.run,
            create_mode=CreateNew,
            permission=0o600,
          )
          self.execute_script(
            step,
            script,
            Int64::min(script_timeout, 2147483647L).to_int(),
            secrets~,
          )
        }
      }
    } catch {
      Stopped(reason) => raise Stopped(reason)
      TransportFailure | Rejected(_) | InvalidResponse => raise Stopped("lost")
      _ => {
        self.upload(
          step.id,
          "stderr",
          if step.uses == "moonhub/setup-moonbit@v1" {
            "runner: MoonBit setup failed\n"
          } else if step.remote {
            "runner: GitHub action execution failed\n"
          } else if step.uses.is_empty() {
            "runner: could not prepare or start step\n"
          } else {
            "runner: source checkout failed\n"
          },
        )
        1
      }
    }
    let state = if code == 0 &&
      @protocol.action_runtime_version(self.assignment.version) &&
      @fs.exists(scratch + "/result-\{index}.json") {
      let bytes = @fs.read_file(scratch + "/result-\{index}.json")
      guard bytes.binary().length() <= 4096 else { raise InvalidResponse }
      let result = @json.parse(bytes.text())
      if result is { "conclusion": "skipped", .. } {
        "skipped"
      } else {
        "success"
      }
    } else if code == 0 {
      "success"
    } else {
      "failure"
    }
    self.step_state(index, state, code)
    if code != 0 {
      failed = true
      if !@protocol.action_runtime_version(self.assignment.version) {
        return "failure"
      }
    }
  }
  if @protocol.action_runtime_version(self.assignment.version) &&
    self.execute_action_posts(scratch, failed) != 0 {
    failed = true
  }
  if failed {
    "failure"
  } else {
    "success"
  }
}

///|
async fn Runtime::checkout(
  self : Runtime,
  scratch : String,
  source : (async () -> Bytes)?,
) -> Unit {
  guard source is Some(fetch) else {
    raise InvalidConfiguration("source unavailable")
  }
  // Previous literal steps may run before checkout, but must not leave paths
  // that could redirect extraction. Runner-owned home/tmp are never in archives.
  guard @fs.readdir(self.options.workspace).all(name => {
    [".home", ".tmp"].contains(name)
  }) else {
    raise InvalidConfiguration("checkout requires an empty source workspace")
  }
  let archive = @async.with_timeout(30000, fetch) catch {
    _ => raise InvalidConfiguration("source download failed")
  }
  self.check_live()
  let archive_path = scratch + "/source.tar"
  @fs.write_file(archive_path, archive, create_mode=CreateNew, permission=0o600)
  extract_source(self.options.workspace, archive_path)
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
    if @platform.windows() {
      "C:/Windows/System32/tar.exe"
    } else {
      "tar"
    },
    ["-xkf", archive, "-C", workspace, "--no-same-owner"],
    inherit_env=false,
    extra_env=@platform.environment(),
  ) catch {
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
  bundle? : async () -> Bytes,
  action_node~ : String = default_action_node(),
  action_node20~ : String = default_action_node20(),
  action_runtime~ : String = default_action_runtime(),
  moonbit_installer~ : async () -> Bytes = fetch_moonbit_installer,
  oidc? : async (@protocol.OidcRuntimeRequest) -> @protocol.OidcRuntime,
  artifacts? : async (@protocol.ArtifactRuntimeRequest) -> @protocol.ArtifactRuntime,
  secrets~ : async (@protocol.SecretRequest) -> @protocol.SecretResponse = _ => {
    raise InvalidConfiguration("secret service unavailable")
  },
) -> Report {
  let options = validate_options(assignment, options)
  let scratch = @fs.tmpdir(prefix="moonhub-runner-")
  defer (@async.protect_from_cancel(() => @fs.rmdir(scratch, recursive=true)) catch {
    _ => ()
  })
  let root = options.workspace
  let options = if @protocol.action_runtime_version(assignment.version) {
    @fs.mkdir(root + "/repository", permission=0o700)
    { ..options, workspace: root + "/repository", }
  } else {
    options
  }
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
    job_outputs: Map([]),
    reporting_until: 0L,
    moon_home: "",
    secrets,
    artifacts,
    oidc,
    action_node,
    action_node20,
    action_runtime,
    action_state_key: execution_nonce() + execution_nonce(),
    action_temp: root + "/.tmp",
    job_home: root + "/.home",
  }
  let completed = @async.handle_cancellation(() => {
    try {
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
      @fs.mkdir(runtime.job_home, permission=0o700)
      @fs.mkdir(runtime.action_temp, permission=0o700)
      let moon_home = runtime.job_home + "/.moon"
      @fs.mkdir(moon_home, permission=0o700)
      for entry in ["bin", "lib", "include", "config.json"] {
        let installed = (if @platform.windows() {
            "C:/moonhub/moon/"
          } else {
            "/opt/moon/"
          }) +
          entry
        if !@platform.windows() && @fs.exists(installed) {
          @fs.symlink(target=installed, moon_home + "/" + entry)
        }
      }
      @async.any([
        () => {
          if @protocol.action_runtime_version(assignment.version) &&
            assignment.job.contents_read &&
            bundle is Some(fetch) {
            try {
              let bytes = @async.with_timeout(30000, fetch)
              @fs.write_file(
                scratch + "/source.bundle",
                bytes,
                create_mode=CreateNew,
                permission=0o600,
              )
              runtime.prepare_source_git(scratch)
            } catch {
              Stopped(reason) => raise Stopped(reason)
              Rejected(code) if [400, 403, 404, 413, 422].contains(code) => {
                runtime.upload(
                  "",
                  "stderr",
                  "runner: source bundle request rejected (HTTP \{code}); source could not be prepared\n",
                )
                raise Stopped("failure")
              }
              TransportFailure | Rejected(_) | InvalidResponse =>
                raise Stopped("lost")
              _ => {
                runtime.upload(
                  "", "stderr", "runner: source bundle preparation failed\n",
                )
                raise Stopped("failure")
              }
            }
          }
          if assignment.job.contents_read &&
            !assignment.job.steps.any(step => {
              (
                !step.remote &&
                ["actions/checkout@v4", "moonhub/checkout@v1"].contains(
                  step.uses,
                )
              ) ||
              (step.remote && step.uses.has_prefix("actions/checkout@"))
            }) &&
            source is Some(_) {
            runtime.checkout(scratch, source) catch {
              _ => {
                runtime.upload("", "stderr", "runner: source checkout failed\n")
                raise Stopped("failure")
              }
            }
          }
          runtime.check_live()
          runtime.execute_steps(scratch, source, moonbit_installer)
        },
        () => runtime.monitor(),
      ])
    } catch {
      Stopped(reason) => reason
      _ => "lost"
    }
  })
  let outcome = completed.unwrap_or("cancelled")
  let report = @async.protect_from_cancel(() => {
    let mut outcome = try {
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
      outputs: runtime.job_outputs,
    }
    let body = ToJson::to_json(request)
    if ![
        @protocol.dataflow_assignment_version, @protocol.dispatch_assignment_version,
        @protocol.variable_assignment_version, @protocol.oidc_assignment_version,
        @protocol.environment_assignment_version,
      ].contains(assignment.version) &&
      body is Object(fields) {
      // Older coordinators validate the original completion field set.
      ignore(fields.remove("outputs"))
    }
    let state = Some(runtime.request("complete", body)) catch {
      Rejected(400) if [
          @protocol.dataflow_assignment_version, @protocol.dispatch_assignment_version,
          @protocol.variable_assignment_version, @protocol.oidc_assignment_version,
          @protocol.environment_assignment_version,
        ].contains(assignment.version) &&
        !runtime.job_outputs.is_empty() => {
        // A definitive rejection did not commit the original completion. The
        // shared run output budget is unknown to the runner, so terminate as
        // failure without outputs instead of leaving an executed attempt live.
        // Never change payload after a conflict or an ambiguous transport error.
        outcome = "failure"
        runtime.upload(
          "", "stderr", "runner: coordinator rejected job outputs; reporting failure without outputs\n",
        ) catch {
          _ => ()
        }
        let rejected : @protocol.CompleteRequest = {
          version: @protocol.version,
          conclusion: outcome,
          last_log_sequence: runtime.sequence.to_string(),
          outputs: Map([]),
        }
        Some(runtime.request("complete", ToJson::to_json(rejected))) catch {
          _ => None
        }
      }
      _ => None
    }
    match state {
      Some(state) if state.state == "completed" =>
        { conclusion: state.conclusion, reported: true, steps: runtime.steps, }
      _ => { conclusion: outcome, reported: false, steps: runtime.steps, }
    }
  })
  if completed is None {
    @async.pause()
  }
  report
}

///|
pub async fn run(
  assignment : @protocol.Assignment,
  token : String,
  options : Options,
  action_node~ : String = default_action_node(),
  action_node20~ : String = default_action_node20(),
  action_runtime~ : String = default_action_runtime(),
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
  execute_assignment(
    assignment,
    options,
    post,
    action_node~,
    action_node20~,
    action_runtime~,
    secrets=request => fetch_secrets(options.server, attempt_id, token, request),
    artifacts=request => {
      fetch_action_grant(
        options.server,
        attempt_id,
        token,
        "artifact-runtime",
        ToJson::to_json(request),
      )
    },
    oidc=request => {
      fetch_action_grant(
        options.server,
        attempt_id,
        token,
        "oidc-runtime",
        ToJson::to_json(request),
      )
    },
    source=() => fetch_source(options.server, attempt_id, token),
    bundle=() => fetch_source(options.server, attempt_id, token, bundle=true),
  )
}

///|
fn valid_secret_env_name(name : String) -> Bool {
  !name.is_empty() &&
  name.length() <= 100 &&
  name.get_char(0) is Some(first) &&
  (first.is_ascii_alphabetic() || first == '_') &&
  name
  .iter()
  .all(ch => ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_') &&
  !["MOONHUB_", "GITHUB_", "RUNNER_", "LD_", "DYLD_"].any(prefix => {
    name.to_upper().has_prefix(prefix)
  }) &&
  ![
    "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "NODE_OPTIONS", "ACTIONS_RUNTIME_TOKEN",
    "ACTIONS_RESULTS_URL", "ACTIONS_RUNTIME_URL", "ACTIONS_CACHE_URL", "ACTIONS_CACHE_SERVICE_V2",
    "ACTIONS_CACHE_MODE", "ACTIONS_ID_TOKEN_REQUEST_URL", "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
  ].contains(name.to_upper())
}

///|
fn default_action_node() -> String {
  if @platform.windows() {
    "C:/moonhub/bin/node.exe"
  } else {
    "/usr/local/bin/node"
  }
}

///|
fn default_action_node20() -> String {
  if @platform.windows() {
    "C:/moonhub/bin/node20.exe"
  } else {
    "/opt/actions/node20/bin/node"
  }
}

///|
fn default_action_runtime() -> String {
  if @platform.windows() {
    "C:/moonhub/actions/runtime.mjs"
  } else {
    "/usr/local/lib/moonhub/actions/runtime.mjs"
  }
}
