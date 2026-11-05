///|
async fn wait_for_docker(options : Options) -> Unit raise ProviderError {
  if @platform.windows() {
    let (code, output) = docker_control(options, [
      "info", "--format", "{{json .}}",
    ])
    guard code == 0 else { raise DockerFailure(code) }
    let info : DockerPlatform = @json.from_json(@json.parse(output)) catch {
      _ =>
        raise InvalidConfiguration(
          "Docker returned invalid platform information.",
        )
    }
    guard info.os_type == "windows" &&
      ["x86_64", "amd64"].contains(info.architecture) &&
      (
        info.kernel_version.has_prefix("10.0 20348 ") ||
        info.kernel_version.has_prefix("10.0.20348.")
      ) else {
      raise InvalidConfiguration(
        "Windows workers require a Windows Server 2022 x64 Docker daemon (build 20348).",
      )
    }
    return
  }
  let code = @process.run(
    options.docker,
    ["info", "--format", "{{.ServerVersion}}"],
    inherit_env=false,
    extra_env=docker_environment(options),
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
    extra_env=docker_environment(options),
  ) catch {
    _ => 1
  }
  if inspected != 0 {
    let pulled = @process.run(
      options.docker,
      ["pull", options.runner_image],
      inherit_env=false,
      extra_env=docker_environment(options),
    ) catch {
      _ => 1
    }
    guard pulled == 0 else { raise DockerFailure(pulled) }
  }
  if @platform.windows() {
    let (code, image) = docker_control(options, [
      "image",
      "inspect",
      "--format",
      "{{.Os}}/{{.Architecture}}/{{.OsVersion}}",
      options.runner_image,
    ])
    guard code == 0 && image.trim().has_prefix("windows/amd64/10.0.20348.") else {
      raise InvalidConfiguration(
        "Runner image must target Windows Server 2022 x64 (build 20348).",
      )
    }
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
    extra_env=docker_environment(options),
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
        extra_env=docker_environment(options),
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
  guard [
      @protocol.version, @protocol.action_assignment_version, @protocol.toolchain_assignment_version,
      @protocol.secret_assignment_version, @protocol.remote_assignment_version,
    ].contains(assignment.version) &&
    assignment.has_valid_numbers() &&
    assignment.state == "leased" &&
    assignment.job.runs_on.contains("windows") == @platform.windows() &&
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
  cleanup_stale_workspaces(options)
  for ;; {
    let assignment = claim(options, provider_token) catch {
      Rejected(code) if code == 401 || code == 403 => raise Rejected(code)
      _ => {
        println("pipeline provider: claim temporarily unavailable")
        @async.sleep(options.poll_ms)
        continue
      }
    }
    match assignment {
      None => @async.sleep(options.poll_ms)
      Some(claimed) => {
        validate_assignment(claimed.assignment)
        execute_assignment(options, claimed.assignment, claimed.attempt_token) catch {
          CleanupFailure => raise CleanupFailure
          _ => println("pipeline provider: runner container failed")
        }
      }
    }
  }
}

///|
priv struct DockerPlatform {
  os_type : String
  architecture : String
  kernel_version : String
}

///|
impl @json.FromJson for DockerPlatform with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "Docker info must be an object"))
  }
  {
    os_type: @json.from_json(
      fields.get("OSType").unwrap_or(Json::null()),
      path=path.add_key("OSType"),
    ),
    kernel_version: @json.from_json(
      fields.get("KernelVersion").unwrap_or(Json::null()),
      path=path.add_key("KernelVersion"),
    ),
    architecture: @json.from_json(
      fields.get("Architecture").unwrap_or(Json::null()),
      path=path.add_key("Architecture"),
    ),
  }
}
