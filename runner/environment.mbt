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
    if label.has_prefix("ubuntu-") || label.has_prefix("debian-") {
      let fields : Map[String, String] = Map([])
      for line in os_release.split("\n") {
        if line.split_once("=") is Some((key, value)) {
          fields[key.to_owned()] = value.trim().trim(chars="\"'").to_owned()
        }
      }
      let distribution = if label.has_prefix("debian-") {
        "debian"
      } else {
        "ubuntu"
      }
      let version = label.split_once("-").unwrap().1.to_owned()
      guard fields.get("ID") == Some(distribution) &&
        (label == "ubuntu-latest" || fields.get("VERSION_ID") == Some(version)) else {
        raise InvalidConfiguration(
          "runner image does not match the requested Linux distribution",
        )
      }
    }
  }
}

///|
async fn check_runner_environment(labels : Array[String]) -> Unit {
  if labels.any(label => ["windows-2022", "windows-2025"].contains(label)) {
    validate_windows_runner_environment(
      labels,
      @platform.windows_build(),
      @platform.architecture(),
    )
  }
  if labels.any(label => {
      label.has_prefix("ubuntu-") || label.has_prefix("debian-")
    }) {
    guard !@platform.windows() else {
      raise InvalidConfiguration("Linux distribution jobs require Linux")
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

///|
pub async fn environment_probe() -> @environment.Probe {
  {
    environment_protocol: 1,
    os_release: if @platform.os() == "linux" {
      @fs.read_file("/etc/os-release").text()
    } else {
      ""
    },
    architecture: @platform.architecture(),
  }
}

///|
async fn check_pinned_environment(
  environment : @environment.Definition,
) -> Unit {
  guard @environment.validate_definition(environment) is None &&
    @platform.os() == "linux" else {
    raise InvalidConfiguration("Invalid pinned Linux environment.")
  }
  let actual = environment_probe()
  guard environment.matches_system(actual.os_release, actual.architecture) else {
    raise InvalidConfiguration(
      "Runner image differs from the pinned Linux environment.",
    )
  }
}

///|
fn validate_windows_runner_environment(
  labels : Array[String],
  build : Int32,
  architecture : String,
) -> Unit raise RunnerError {
  guard architecture == "x64" && !labels.contains("arm64") else {
    raise InvalidConfiguration(
      "Windows hosted environments require an x64 executor",
    )
  }
  for label in labels {
    let expected = match label {
      "windows-2022" => 20348
      "windows-2025" => 26100
      _ => continue
    }
    guard build == expected else {
      raise InvalidConfiguration(
        "runner image does not match the requested Windows environment",
      )
    }
  }
}
