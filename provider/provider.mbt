///|
async fn wait_for_docker(options : Options) -> Unit raise ProviderError {
  if @platform.windows() {
    ignore(windows_docker_isolation(options))
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
    verify_windows_container(options)
  }
}

///|
async fn verify_windows_container(
  options : Options,
) -> Unit raise ProviderError {
  let isolation = windows_docker_isolation(options)
  let name = "moonhub-pipeline-preflight-" + random_hex(16)
  defer (@async.protect_from_cancel(() => {
    ignore(docker_control(options, ["rm", "-f", name]))
    let (code, remaining) = docker_control(options, [
      "ps",
      "-aq",
      "--filter",
      "name=^" + name + "$",
    ])
    guard code == 0 && remaining.trim().is_empty() else { raise CleanupFailure }
  }) catch {
    _ => raise CleanupFailure
  })
  // A running Windows daemon and a cached image do not prove that Hyper-V is
  // enabled/usable. Verify the real isolation path before advertising ready.
  @async.with_timeout(90000, () => {
    let code = @process.run(
      options.docker,
      [
        "run",
        "--rm",
        "--name",
        name,
        "--isolation",
        isolation,
        "--network",
        "none",
        "--user",
        "ContainerUser",
        "--memory",
        options.memory,
        "--cpu-count",
        options.cpus,
        "--entrypoint",
        "cmd.exe",
        options.runner_image,
        "/d",
        "/s",
        "/c",
        "exit /b 0",
      ],
      inherit_env=false,
      extra_env=docker_environment(options),
    )
    guard code == 0 else {
      raise InvalidConfiguration(
        "Windows container preflight failed; verify Docker, Hyper-V and the task image.",
      )
    }
  }) catch {
    _ =>
      raise InvalidConfiguration(
        "Windows container preflight failed; verify Docker, Hyper-V and the task image.",
      )
  }
}

///|
async fn windows_docker_isolation(
  options : Options,
) -> String raise ProviderError {
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
  windows_container_isolation(info)
}

///|
fn windows_container_isolation(
  info : DockerPlatform,
) -> String raise ProviderError {
  guard info.os_type == "windows" &&
    ["x86_64", "amd64"].contains(info.architecture) else {
    raise InvalidConfiguration(
      "Use a Windows x64 Docker daemon, not Linux containers.",
    )
  }
  let kernel = info.kernel_version
  let build = if kernel.strip_prefix("10.0 ") is Some(rest) {
    @protocol.parse_decimal(rest.split(" ").next().unwrap_or("").to_owned())
  } else if kernel.strip_prefix("10.0.") is Some(rest) {
    @protocol.parse_decimal(rest.split(".").next().unwrap_or("").to_owned())
  } else {
    None
  }
  if build == Some(20348L) {
    return "process"
  }
  let operating_system = info.operating_system.to_lower()
  // Moby formats client releases as "Microsoft Windows Version ..." without
  // a marketing version; older engines can retain the Windows 10 product name.
  // Build 22000+ distinguishes Windows 11 clients, while Server is excluded.
  if (
      operating_system.has_prefix("microsoft windows ") ||
      operating_system.has_prefix("windows ")
    ) &&
    !operating_system.contains("server") &&
    build is Some(build) &&
    build >= 22000L {
    return "hyperv"
  }
  raise InvalidConfiguration(
    "Use Windows Server 2022 x64 or Windows 11 x64 with Hyper-V and Windows containers enabled.",
  )
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
  runner_os~ : String = if @platform.windows() { "windows" } else { "linux" },
) -> Unit raise ProviderError {
  guard [
      @protocol.version, @protocol.action_assignment_version, @protocol.toolchain_assignment_version,
      @protocol.secret_assignment_version, @protocol.remote_assignment_version, @protocol.scheduling_assignment_version,
      @protocol.dataflow_assignment_version, @protocol.dispatch_assignment_version,
    ].contains(assignment.version) &&
    assignment.has_valid_numbers() &&
    assignment.state == "leased" &&
    @platform.job_os(assignment.job.runs_on) == runner_os &&
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
  operating_system : String
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
    operating_system: match fields.get("OperatingSystem") {
      Some(value) =>
        @json.from_json(value, path=path.add_key("OperatingSystem"))
      None => ""
    },
    architecture: @json.from_json(
      fields.get("Architecture").unwrap_or(Json::null()),
      path=path.add_key("Architecture"),
    ),
  }
}
