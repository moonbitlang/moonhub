///|
fn container_name(attempt_id : String) -> String {
  "moonhub-pipeline-\{attempt_id}"
}

///|
fn container_args(
  options : Options,
  assignment_path : String,
  attempt_id : String,
  workspace_volume : String,
) -> Array[String] {
  let args = [
    "run",
    "--interactive",
    "--rm",
    "--name",
    container_name(attempt_id),
    "--read-only",
    "--cap-drop",
    "ALL",
    "--security-opt",
    "no-new-privileges",
    "--pids-limit",
    options.pids_limit.to_string(),
    "--memory",
    options.memory,
    "--cpus",
    options.cpus,
    "--tmpfs",
    "/tmp:rw,noexec,nosuid,nodev,size=64m",
    "--mount",
    "type=volume,src=\{workspace_volume},dst=/workspace",
    "--mount",
    "type=bind,src=\{assignment_path},dst=/control/assignment.json,readonly",
  ]
  if !options.network.is_empty() {
    args.push("--network")
    args.push(options.network)
  }
  if !options.runner_host.is_empty() {
    args.push("--add-host")
    args.push(options.runner_host + ":" + options.runner_host_ip)
  }
  args.push(options.runner_image)
  args.push("--server")
  args.push(options.runner_server)
  args.push("--assignment")
  args.push("/control/assignment.json")
  if options.allow_http {
    args.push("--allow-http")
  }
  args
}

///|
async fn read_bounded(
  reader : @process.ReadFromProcess,
  limit : Int32,
) -> String {
  let bytes : Array[Byte] = []
  for ;; {
    let chunk = reader.read_some(max_len=4096)
    match chunk {
      None => break
      Some(chunk) =>
        // Continue draining a noisy subprocess after reaching the retained limit.
        for byte in chunk {
          if bytes.length() < limit {
            bytes.push(byte)
          }
        }
    }
  }
  @utf8.decode_lossy(Bytes::from_array(bytes))
}

///|
async fn run_container(
  options : Options,
  assignment : @protocol.Assignment,
  attempt_token : String,
  assignment_path : String,
  workspace_volume : String,
) -> AssignmentResult {
  let args = container_args(
    options,
    assignment_path,
    assignment.attempt_id,
    workspace_volume,
  )
  @async.with_timeout(
    assignment.job.timeout_minutes * 60000 + 90000,
    () => {
      @async.with_task_group(group => {
        let (stdout, stdout_writer) = @process.read_from_process()
        defer stdout.close()
        let (stderr, stderr_writer) = @process.read_from_process()
        defer stderr.close()
        let (stdin, stdin_writer) = @process.write_to_process()
        defer stdin_writer.close()
        let process = @process.spawn(
          group,
          options.docker,
          args,
          inherit_env=false,
          extra_env={
            "PATH": "/usr/bin:/bin",
            "DOCKER_HOST": options.docker_host,
          },
          stdin~,
          stdout=stdout_writer,
          stderr=stderr_writer,
          cancel_handler=@process.graceful_cancel(timeout=15000),
        )
        let output = group.spawn(() => read_bounded(stdout, 65536))
        let diagnostic = group.spawn(() => read_bounded(stderr, 8192))
        group.spawn_bg(() => {
          stdin_writer.write(attempt_token + "\n")
          stdin_writer.close()
        })
        let code = process.wait()
        let output = output.wait()
        let diagnostic_text = diagnostic.wait()
        if code != 0 && !diagnostic_text.trim().is_empty() {
          println(
            "pipeline provider: docker: \{diagnostic_text.replace_all(old=attempt_token, new="[REDACTED]").trim()}",
          )
        }
        let report = @json.parse(output.trim()) catch {
          _ => raise DockerFailure(code)
        }
        guard report is Object(fields) else { raise DockerFailure(code) }
        let reported = fields.get("reported") is Some(True)
        if !reported {
          // Keep provider logs generic: Docker diagnostics can contain user output.
          println("pipeline provider: runner returned an unconfirmed result")
        }
        { code, reported, }
      })
    },
    error=Stopped,
  )
}

///|
async fn execute_assignment(
  options : Options,
  assignment : @protocol.Assignment,
  attempt_token : String,
) -> Unit {
  let attempt_id = assignment.attempt_id
  let root = options.workspace_root + "/" + attempt_id
  @fs.mkdir(root, permission=0o700) catch {
    _ => raise DockerFailure(125)
  }
  defer (@async.protect_from_cancel(() => @fs.rmdir(root, recursive=true)) catch {
    _ => ()
  })
  let workspace_volume = "moonhub-workspace-\{attempt_id}-\{random_hex(16)}"
  // Protect cleanup from both runner failure and provider cancellation. An
  // uncertain cleanup is fatal: restarting must reconcile before more claims.
  defer @async.protect_from_cancel(() => {
    cleanup_assignment(options, attempt_id, workspace_volume)
  })
  create_workspace(options, workspace_volume)
  let assignment_path = root + "/assignment.json"
  @fs.write_file(
    assignment_path,
    ToJson::to_json(assignment).stringify(),
    create_mode=@fs.CreateNew,
    permission=0o600,
  )
  let result = run_container(
    options, assignment, attempt_token, assignment_path, workspace_volume,
  ) catch {
    Stopped => raise Stopped
    _ => raise DockerFailure(125)
  }
  guard result.reported else { raise DockerFailure(result.code) }
}
