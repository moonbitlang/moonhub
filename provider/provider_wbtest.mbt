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
  let args = container_args(options, "/run/assignment.json", 42L)
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
