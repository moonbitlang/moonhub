///|
let workspace_label : String = "io.moonhub.pipeline.workspace=1"

///|
async fn docker_control(
  options : Options,
  args : Array[String],
) -> (Int32, String) raise ProviderError {
  @async.with_timeout(15000, () => {
    let (code, output) = @process.collect_output_merged(
      options.docker,
      args,
      inherit_env=false,
      extra_env=docker_environment(options),
    )
    (code, output.text())
  }) catch {
    _ => raise DockerFailure(125)
  }
}

///|
async fn create_workspace(
  options : Options,
  name : String,
  container : String,
) -> Unit raise ProviderError {
  let (code, output) = docker_control(options, [
    "volume", "create", "--label", workspace_label, name,
  ])
  guard code == 0 && output.trim() == name else { raise DockerFailure(code) }
  if @platform.windows() {
    // A named volume replaces the image directory's ACL. Initialize only this
    // fresh job volume before the unprivileged executor receives any input.
    let isolation = windows_docker_isolation(options)
    @async.with_timeout(90000, () => {
      let code = @process.run(
        options.docker,
        windows_workspace_initialization_args(
          options, name, container, isolation,
        ),
        inherit_env=false,
        extra_env=docker_environment(options),
      )
      guard code == 0 else { raise DockerFailure(code) }
    }) catch {
      _ => raise DockerFailure(125)
    }
  }
}

///|
async fn prepare_workspace(
  options : Options,
) -> PreparedWorkspace raise ProviderError {
  let nonce = random_hex(16)
  let workspace = {
    volume: "moonhub-workspace-prepared-" + nonce,
    container: "moonhub-pipeline-workspace-" + nonce,
  }
  errdefer (@async.protect_from_cancel(() => {
    cleanup_workspace(options, workspace.container, workspace.volume)
  }) catch {
    _ => raise CleanupFailure
  })
  create_workspace(options, workspace.volume, workspace.container)
  workspace
}

///|
fn windows_workspace_initialization_args(
  options : Options,
  volume : String,
  container : String,
  isolation : String,
) -> Array[String] {
  [
    "run",
    "--rm",
    "--name",
    container,
    "--isolation",
    isolation,
    "--network",
    "none",
    "--user",
    "ContainerAdministrator",
    "--memory",
    options.memory,
    "--cpu-count",
    options.cpus,
    "--mount",
    "type=volume,src=\{volume},dst=C:\\workspace",
    "--entrypoint",
    "C:\\Windows\\System32\\icacls.exe",
    options.runner_image,
    "C:\\workspace",
    "/grant",
    "*S-1-5-32-545:(OI)(CI)M",
  ]
}

///|
async fn remove_workspace(
  options : Options,
  name : String,
) -> Unit raise ProviderError {
  let (code, _) = docker_control(options, ["volume", "rm", name])
  if code == 0 {
    return
  }
  // Creation may have failed before allocating the volume. A successful list
  // distinguishes absence from a daemon/permission error, without parsing stderr.
  let (code, remaining) = docker_control(options, [
    "volume",
    "ls",
    "-q",
    "--filter",
    "name=^" + name + "$",
  ])
  guard code == 0 && remaining.trim().is_empty() else { raise CleanupFailure }
}

///|
async fn cleanup_workspace(
  options : Options,
  container : String,
  workspace_volume : String,
) -> Unit raise ProviderError {
  try {
    // --rm normally removed the container already. Docker refuses volume
    // removal while it is still referenced by a container, including stopped ones.
    ignore(docker_control(options, ["rm", "-f", container]))
    remove_workspace(options, workspace_volume)
  } catch {
    _ => {
      println(
        "pipeline provider: workspace cleanup failed; refusing further claims",
      )
      raise CleanupFailure
    }
  }
}

///|
async fn cleanup_stale_workspaces(
  options : Options,
) -> Unit raise ProviderError {
  let (code, output) = docker_control(options, [
    "volume",
    "ls",
    "-q",
    "--filter",
    "label=" + workspace_label,
  ])
  guard code == 0 else { raise DockerFailure(code) }
  for raw in output.split("\n") {
    let name = raw.trim().to_owned()
    if name.is_empty() {
      continue
    }
    guard name.has_prefix("moonhub-workspace-") &&
      name.length() <= 128 &&
      name
      .iter()
      .all(ch => ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '-') else {
      raise InvalidConfiguration("Docker returned an invalid workspace name")
    }
    remove_workspace(options, name)
  }
}

///|
fn docker_environment(options : Options) -> Map[String, String] {
  let env = @platform.environment()
  env["DOCKER_HOST"] = options.docker_host
  env
}
