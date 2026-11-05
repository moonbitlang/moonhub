///|
fn test_options() -> Options {
  {
    server: "https://moonhub.example",
    runner_server: "https://moonhub.example",
    runner_image: "registry.example/moonhub-runner:dev",
    docker: "/usr/bin/docker",
    docker_host: "unix:///var/run/docker.sock",
    network: "bridge",
    runner_host: "",
    runner_host_ip: "",
    workspace_root: "/tmp/moonhub-provider",
    poll_ms: 1000,
    allow_http: false,
    memory: "512m",
    cpus: "1",
    pids_limit: 128,
  }
}

///|
test "provider validates origins and builds a constrained runner command" {
  let options = test_options()
  validate_options(options)
  let args = container_args(
    options, "/run/assignment.json", "42", "moonhub-workspace-42-test",
  )
  if @platform.windows() {
    assert_true(args.contains("--isolation"))
    assert_true(args.contains("process"))
    assert_true(args.contains("ContainerUser"))
    assert_true(!args.contains("--read-only"))
    assert_true(!args.contains("--cap-drop"))
    assert_true(!args.contains("--pids-limit"))
    assert_true(
      args.contains(
        "type=volume,src=moonhub-workspace-42-test,dst=C:\\workspace",
      ),
    )
    let hyperv = container_args(
      options,
      "C:/control/assignment.json",
      "42",
      "workspace",
      windows_isolation="hyperv",
    )
    assert_true(hyperv.contains("hyperv"))
    assert_true(!hyperv.contains("process"))
    return
  }
  assert_true(args.contains("--read-only"))
  assert_true(args.contains("--interactive"))
  assert_true(args.contains("--cap-drop"))
  assert_true(args.contains("ALL"))
  assert_true(args.contains("no-new-privileges"))
  assert_true(args.contains("--pids-limit"))
  assert_true(args.contains("--memory"))
  assert_true(args.contains("--cpus"))
  assert_true(args.contains("--rm"))
  assert_true(!args.contains("--privileged"))
  assert_true(!args.contains("/var/run/docker.sock"))
  assert_true(args.contains("registry.example/moonhub-runner:dev"))
  assert_true(
    args.contains("type=volume,src=moonhub-workspace-42-test,dst=/workspace"),
  )
}

///|
test "workspaces are isolated disk volumes while scratch memory stays bounded" {
  let options = test_options()
  let args = container_args(
    options, "/run/assignment.json", "42", "moonhub-workspace-42-fresh",
  )
  if @platform.windows() {
    assert_true(
      args.contains(
        "type=volume,src=moonhub-workspace-42-fresh,dst=C:\\workspace",
      ),
    )
    assert_true(!args.contains("--tmpfs"))
    assert_true(args.contains("--memory"))
    assert_true(args.contains("--cpu-count"))
    return
  }
  assert_true(args.contains("/tmp:rw,noexec,nosuid,nodev,size=64m"))
  assert_true(
    args.contains("type=volume,src=moonhub-workspace-42-fresh,dst=/workspace"),
  )
  assert_true(!args.any(arg => arg.has_prefix("/workspace:")))
  assert_true(!args.any(arg => arg.contains("volume-nocopy")))
  assert_true(args.contains("--memory"))
  assert_true(args.contains("--cpus"))
}

///|
test "provider rejects unsafe runner server and partial host mappings" {
  let options = test_options()
  try validate_origin("http://moonhub.example/path", true) catch {
    InvalidConfiguration(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted runner path")
  }
  try validate_options({ ..options, runner_host: "moonhub", }) catch {
    InvalidConfiguration(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted partial host mapping")
  }
  for network in ["host", "container:controller"] {
    try validate_options({ ..options, network, }) catch {
      InvalidConfiguration(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted shared network namespace")
    }
  }
}

///|
test "Windows container isolation follows the actual daemon host" {
  let server : DockerPlatform = {
    os_type: "windows",
    architecture: "amd64",
    kernel_version: "10.0 20348 (20348.1.amd64fre)",
    operating_system: "Microsoft Windows Server 2022 Datacenter",
  }
  assert_eq(windows_container_isolation(server), "process")
  assert_eq(
    windows_container_isolation({ ..server, kernel_version: "10.0.20348.2402", }),
    "process",
  )
  for kernel_version in ["10.0 22631 (22631.1.amd64fre)", "10.0.26100.4652"] {
    assert_eq(
      windows_container_isolation({
        ..server,
        operating_system: "Microsoft Windows 11 Pro",
        kernel_version,
      }),
      "hyperv",
    )
  }
  for
    invalid in [
      { ..server, os_type: "linux", },
      { ..server, architecture: "aarch64", },
      {
        ..server,
        kernel_version: "10.0.17763.1",
        operating_system: "Windows 10 Pro",
      },
      {
        ..server,
        kernel_version: "10.0.26100.1",
        operating_system: "Windows Server 2025",
      },
      {
        ..server,
        kernel_version: "garbled",
        operating_system: "Windows 11 Pro",
      },
    ] {
    try windows_container_isolation(invalid) catch {
      InvalidConfiguration(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted an unsupported Docker host")
    }
  }
}

///|
test "worker retirement recovers while delayed heartbeat conflicts preserve active work" {
  assert_true(permanent_worker_rejection(409, "ready", "ready"))
  assert_true(permanent_worker_rejection(409, "starting", "starting"))
  assert_true(!permanent_worker_rejection(409, "ready", "busy"))
  assert_true(!permanent_worker_rejection(409, "busy", "busy"))
  assert_true(!permanent_worker_rejection(409, "ready", "starting"))
  assert_true(!permanent_worker_rejection(503, "ready", "ready"))
  assert_true(permanent_worker_rejection(401, "busy", "busy"))
  assert_true(permanent_worker_rejection(403, "starting", "busy"))
}
