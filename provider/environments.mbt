///|
async fn verify_linux_environment(
  options : Options,
  environment : @environment.Definition,
) -> Unit {
  guard @environment.validate_definition(environment) is None else {
    raise InvalidConfiguration("Invalid Linux execution environment.")
  }
  let name = "moonhub-pipeline-environment-" + random_hex(16)
  defer @async.protect_from_cancel(() => {
    ignore(docker_control(options, ["rm", "-f", name]))
    let (code, remaining) = docker_control(options, [
      "ps",
      "-aq",
      "--filter",
      "name=^" + name + "$",
    ])
    guard code == 0 && remaining.trim().is_empty() else { raise CleanupFailure }
  })
  @async.with_timeout(60000, () => {
    let (code, output) = docker_control(options, [
      "run",
      "--rm",
      "--name",
      name,
      "--read-only",
      "--network",
      "none",
      "--user",
      "10001:10001",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--pids-limit",
      "32",
      "--memory",
      "256m",
      "--cpus",
      "1",
      "--entrypoint",
      "/usr/local/bin/moonhub-runner",
      environment.image,
      "execute",
      "--probe-environment",
    ])
    guard code == 0 else {
      raise InvalidConfiguration(
        "Use a task image with multiple-environment support.",
      )
    }
    let actual : @environment.Probe = @json.from_json(@json.parse(output)) catch {
      _ =>
        raise InvalidConfiguration(
          "Runner image returned an invalid environment probe.",
        )
    }
    guard actual.environment_protocol == 1 &&
      environment.matches_system(actual.os_release, actual.architecture) else {
      raise InvalidConfiguration(
        "Runner image does not provide the configured Linux distribution and architecture.",
      )
    }
  })
}
