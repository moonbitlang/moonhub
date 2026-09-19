///|
async fn wait_for_docker(options : Options) -> Unit raise ProviderError {
  let code = @process.run(
    options.docker,
    ["info", "--format", "{{.ServerVersion}}"],
    inherit_env=false,
    extra_env={ "PATH": "/usr/bin:/bin", "DOCKER_HOST": options.docker_host },
  ) catch {
    _ => raise TransportFailure
  }
  guard code == 0 else { raise DockerFailure(code) }
}

///|
async fn ensure_runner_image(options : Options) -> Unit raise ProviderError {
  let inspected = @process.run(
    options.docker,
    ["image", "inspect", "--format", "{{.Id}}", options.runner_image],
    inherit_env=false,
    extra_env={ "PATH": "/usr/bin:/bin", "DOCKER_HOST": options.docker_host },
  ) catch {
    _ => 1
  }
  if inspected != 0 {
    let pulled = @process.run(
      options.docker,
      ["pull", options.runner_image],
      inherit_env=false,
      extra_env={ "PATH": "/usr/bin:/bin", "DOCKER_HOST": options.docker_host },
    ) catch {
      _ => 1
    }
    guard pulled == 0 else { raise DockerFailure(pulled) }
  }
}

///|
async fn cleanup_stale_containers(
  options : Options,
) -> Unit raise ProviderError {
  let (code, output) = @process.collect_output_merged(
    options.docker,
    ["ps", "-aq", "--filter", "name=^moonhub-pipeline-"],
    inherit_env=false,
    extra_env={ "PATH": "/usr/bin:/bin", "DOCKER_HOST": options.docker_host },
  ) catch {
    _ => raise DockerFailure(125)
  }
  guard code == 0 else { raise DockerFailure(code) }
  let output_text = output.text() catch {
    _ => raise InvalidConfiguration("Docker returned invalid output")
  }
  for raw_id in output_text.split("\n") {
    let id = raw_id.trim()
    if !id.is_empty() {
      guard id.iter().all(ch => ch.is_ascii_alphabetic() || ch.is_ascii_digit()) else {
        raise InvalidConfiguration("Docker returned an invalid container id")
      }
      let removed = @process.run(
        options.docker,
        ["rm", "-f", id.to_owned()],
        inherit_env=false,
        extra_env={
          "PATH": "/usr/bin:/bin",
          "DOCKER_HOST": options.docker_host,
        },
      ) catch {
        _ => 125
      }
      guard removed == 0 else { raise DockerFailure(removed) }
    }
  }
}

///|
fn validate_assignment(
  assignment : @protocol.Assignment,
) -> Unit raise ProviderError {
  guard assignment.version == @protocol.version &&
    assignment.attempt_id > 0L &&
    assignment.state == "leased" &&
    assignment.job.timeout_minutes >= 1 &&
    assignment.job.timeout_minutes <= 360 &&
    assignment.job.steps.length() > 0 &&
    assignment.job.steps.length() <= 64 else {
    raise InvalidConfiguration("claim returned an invalid assignment")
  }
}

///|
pub async fn run(
  options : Options,
  provider_token : String,
) -> Unit raise ProviderError {
  validate_options(options)
  guard provider_token.length() == 64 &&
    provider_token
    .iter()
    .all(ch => ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f')) else {
    raise InvalidConfiguration(
      "provider token must be 64 lowercase hexadecimal characters",
    )
  }
  let workspace_exists = @fs.exists(options.workspace_root) catch {
    _ => raise InvalidConfiguration("cannot inspect provider workspace")
  }
  if !workspace_exists {
    @fs.mkdir(options.workspace_root, recursive=true, permission=0o700) catch {
      _ => raise InvalidConfiguration("cannot create provider workspace")
    }
  } else {
    let workspace_kind = @fs.kind(options.workspace_root, follow_symlink=false) catch {
      _ => raise InvalidConfiguration("cannot inspect provider workspace")
    }
    guard workspace_kind is Directory else {
      raise InvalidConfiguration("provider workspace is not a directory")
    }
  }
  wait_for_docker(options)
  ensure_runner_image(options)
  cleanup_stale_containers(options)
  for ;; {
    let assignment = claim(options, provider_token) catch {
      err if @async.is_cancellation_error(err) => raise Stopped
      Rejected(code) if code == 401 || code == 403 => raise Rejected(code)
      _ => {
        println("pipeline provider: claim temporarily unavailable")
        @async.sleep(options.poll_ms) catch {
          _ => raise Stopped
        }
        continue
      }
    }
    match assignment {
      None => @async.sleep(options.poll_ms) catch { _ => raise Stopped }
      Some(claimed) => {
        validate_assignment(claimed.assignment)
        execute_assignment(options, claimed.assignment, claimed.attempt_token) catch {
          err if @async.is_cancellation_error(err) => raise Stopped
          _ => println("pipeline provider: runner container failed")
        }
      }
    }
  }
}
