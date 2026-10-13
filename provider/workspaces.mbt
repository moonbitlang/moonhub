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
      extra_env={ "PATH": "/usr/bin:/bin", "DOCKER_HOST": options.docker_host },
    )
    (code, output.text())
  }) catch {
    err if @async.is_cancellation_error(err) => raise Stopped
    _ => raise DockerFailure(125)
  }
}

///|
async fn create_workspace(
  options : Options,
  name : String,
) -> Unit raise ProviderError {
  let (code, output) = docker_control(options, [
    "volume", "create", "--label", workspace_label, name,
  ])
  guard code == 0 && output.trim() == name else { raise DockerFailure(code) }
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
async fn cleanup_assignment(
  options : Options,
  attempt_id : String,
  workspace_volume : String,
) -> Unit raise ProviderError {
  try {
    // --rm normally removed the container already. Docker refuses volume
    // removal while it is still referenced by a container, including stopped ones.
    ignore(docker_control(options, ["rm", "-f", container_name(attempt_id)]))
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
