///|
fn validate_runner_environment(
  labels : Array[String],
  os_release : String,
  architecture : String,
) -> Unit raise RunnerError {
  let architecture = match architecture.trim().to_owned() {
    "x86_64" | "amd64" => "x64"
    "aarch64" => "arm64"
    other => other
  }
  guard ["x64", "arm64"].all(arch => {
    !labels.contains(arch) || arch == architecture
  }) else {
    raise InvalidConfiguration(
      "runner architecture does not match the requested capability",
    )
  }
  for label in labels {
    if label.has_prefix("ubuntu-") {
      let fields : Map[String, String] = Map([])
      for line in os_release.split("\n") {
        if line.split_once("=") is Some((key, value)) {
          fields[key.to_owned()] = value.trim().trim(chars="\"'").to_owned()
        }
      }
      guard fields.get("ID") == Some("ubuntu") &&
        (
          label == "ubuntu-latest" ||
          fields.get("VERSION_ID") ==
          Some(label.strip_prefix("ubuntu-").unwrap().to_owned())
        ) else {
        raise InvalidConfiguration(
          "runner image does not match the requested Ubuntu environment",
        )
      }
    }
  }
}

///|
async fn check_runner_environment(labels : Array[String]) -> Unit {
  if labels.any(label => label.has_prefix("ubuntu-")) {
    guard !@platform.windows() else {
      raise InvalidConfiguration("Ubuntu jobs require Linux")
    }
    let release = @fs.read_file("/etc/os-release").text() catch { _ => "" }
    let (code, arch) = @process.collect_output_merged(
      "/usr/bin/uname",
      ["-m"],
      inherit_env=false,
      extra_env=@platform.environment(),
    )
    guard code == 0 else {
      raise InvalidConfiguration("cannot inspect runner architecture")
    }
    validate_runner_environment(labels, release, arch.text())
  }
}
