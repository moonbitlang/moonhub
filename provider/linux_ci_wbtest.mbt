///|
test "privileged CI is opt-in and has no host Docker socket or shared namespaces" {
  if @platform.os() != "linux" {
    return
  }
  let options = { ..test_options(), linux_ci: true, }
  let args = container_args(
    options, "/run/job.json", "1", "moonhub-workspace-ci",
  )
  assert_true(args.contains("--privileged"))
  assert_true(args.contains("--linux-ci"))
  assert_true(args.contains("private"))
  assert_false(args.contains("--read-only"))
  assert_false(args.contains("no-new-privileges"))
  assert_false(
    args.any(value => {
      value.contains("docker.sock") || value.contains("/run/moonhub-runner")
    }),
  )
  let normal = container_args(
    test_options(),
    "/run/job.json",
    "1",
    "moonhub-workspace-default",
  )
  assert_false(normal.contains("--privileged"))
  assert_false(normal.contains("--linux-ci"))
  let managed = { ..managed_test_options(), base: options, }
  assert_eq(config_defaults(managed).get("execution_mode"), Some("linux-ci"))
  assert_eq(
    @protocol.validate_config(config_schema(managed), config_defaults(managed)),
    None,
  )
  let (_, command) = worker_bootstrap_command(
    "us-west-2",
    "/moonhub-runner/ci/i-test",
    "linux",
    linux_ci=true,
  )
  assert_true(command.contains("moonhub-ci-host"))
  assert_false(command.contains("--linux-ci --unsafe-local"))
  try configured_options(test_options(), config_defaults(managed)) catch {
    InvalidConfiguration(_) => ()
    err => raise err
  } noraise {
    _ => fail("ordinary worker accepted CI execution")
  }
}
