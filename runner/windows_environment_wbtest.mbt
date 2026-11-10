///|
test "Windows environment guards require the actual userland build and executor architecture" {
  for (label, build) in [("windows-2022", 20348), ("windows-2025", 26100)] {
    let labels = ["self-hosted", "windows", "x64", label]
    validate_windows_runner_environment(labels, build, "x64")
    for
      (actual, arch) in [
        (0, "x64"),
        (17763, "x64"),
        (build, "arm64"),
        (build, "unknown"),
      ] {
      try validate_windows_runner_environment(labels, actual, arch) catch {
        InvalidConfiguration(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted a mismatched Windows environment")
      }
    }
  }
  try
    validate_windows_runner_environment(["windows-2025"], 20348, "x64")
  catch {
    InvalidConfiguration(_) => ()
    err => raise err
  } noraise {
    _ => fail("Server 2022 impersonated Server 2025")
  }
}
