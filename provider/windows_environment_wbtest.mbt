///|
test "Windows task-image metadata accepts only supported x64 OS builds" {
  assert_eq(windows_task_image_build("windows/amd64/10.0.20348.1"), 20348L)
  assert_eq(windows_task_image_build("windows/amd64/10.0.26100.33674"), 26100L)
  for
    image in [
      "windows/arm64/10.0.26100.1", "linux/amd64/10.0.26100.1", "windows/amd64/10.0.26100.",
      "windows/amd64/10.0.26100.01", "windows/amd64/10.0.17763.1",
    ] {
    try ignore(windows_task_image_build(image)) catch {
      InvalidConfiguration(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted invalid image metadata")
    }
  }
}

///|
test "Server 2025 uses the supported host-image compatibility matrix" {
  let server : DockerPlatform = {
    os_type: "windows",
    architecture: "amd64",
    kernel_version: "10.0.26100.33674",
    operating_system: "Microsoft Windows Server 2025 Datacenter",
  }
  assert_eq(windows_container_isolation(server, image_build=26100L), "process")
  assert_eq(windows_container_isolation(server, image_build=20348L), "process")
  try
    ignore(
      windows_container_isolation(
        {
          ..server,
          kernel_version: "10.0.20348.1",
          operating_system: "Microsoft Windows Server 2022 Datacenter",
        },
        image_build=26100L,
      ),
    )
  catch {
    InvalidConfiguration(_) => ()
    err => raise err
  } noraise {
    _ => fail("ran a 2025 image on an unsupported 2022 host")
  }
  try
    ignore(
      windows_container_isolation(
        { ..server, operating_system: "Windows 11 Pro", },
        image_build=26100L,
      ),
    )
  catch {
    InvalidConfiguration(_) => ()
    err => raise err
  } noraise {
    _ => fail("claimed an unverified Windows 11/2025 combination")
  }
}
