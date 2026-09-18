///|
fn container_name(attempt_id : Int64) -> String {
  "moonhub-pipeline-\{attempt_id}"
}

///|
fn container_args(
  options : Options,
  assignment_path : String,
  attempt_id : Int64,
) -> Array[String] {
  let args = [
    "run",
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
    "--tmpfs",
    "/workspace:rw,exec,nosuid,nodev,size=1g,uid=10001,gid=10001,mode=0700",
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
async fn read_bounded(reader : @process.ReadFromProcess, limit : Int) -> String {
  let bytes : Array[Byte] = []
  for ;; {
    let chunk = reader.read_some(max_len=4096) catch { _ => None }
    match chunk {
      None => break
      Some(chunk) => {
        guard bytes.length() + chunk.length() <= limit else { break }
        for byte in chunk {
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
) -> AssignmentResult {
  let args = container_args(options, assignment_path, assignment.attempt_id)
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
        ignore(diagnostic.wait())
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
  let root = options.workspace_root + "/" + assignment.attempt_id.to_string()
  @fs.mkdir(root, permission=0o700) catch {
    _ => raise DockerFailure(125)
  }
  defer (@async.protect_from_cancel(() => @fs.rmdir(root, recursive=true)) catch {
    _ => ()
  })
  let assignment_path = root + "/assignment.json"
  @fs.write_file(
    assignment_path,
    ToJson::to_json(assignment).stringify(),
    create_mode=@fs.CreateNew,
    permission=0o600,
  )
  let result = run_container(
    options, assignment, attempt_token, assignment_path,
  ) catch {
    Stopped => {
      ignore(
        @process.run(
          options.docker,
          ["rm", "-f", container_name(assignment.attempt_id)],
          inherit_env=false,
          extra_env={
            "PATH": "/usr/bin:/bin",
            "DOCKER_HOST": options.docker_host,
          },
        ),
      )
      raise Stopped
    }
    _ => {
      ignore(
        @process.run(
          options.docker,
          ["rm", "-f", container_name(assignment.attempt_id)],
          inherit_env=false,
          extra_env={
            "PATH": "/usr/bin:/bin",
            "DOCKER_HOST": options.docker_host,
          },
        ),
      )
      raise DockerFailure(125)
    }
  }
  guard result.reported else { raise DockerFailure(result.code) }
}
