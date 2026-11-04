///|
fn managed_test_options() -> ManagedOptions {
  {
    base: test_options(),
    name: "test",
    mode: "asg",
    state_dir: "/tmp/not-used",
    registration_token_file: "",
    aws: "aws",
    region: "us-west-2",
    asg: "test-on",
    spot_asg: "test-spot",
    launch_template: "lt-example",
    parameter_prefix: "/moonhub-runner/test",
    instance_types: ["m6a.large", "c6a.large"],
  }
}

///|
test "backend schema exposes only locally allowed instance types and purchase policy" {
  let options = managed_test_options()
  let defaults = config_defaults(options)
  assert_eq(@protocol.validate_config(config_schema(options), defaults), None)
  assert_eq(defaults.get("instance_type"), Some("m6a.large"))
  assert_eq(defaults.get("standby_workers"), Some("0"))
  let invalid_standby = config_defaults(options)
  invalid_standby["standby_workers"] = "21"
  assert_true(
    @protocol.validate_config(config_schema(options), invalid_standby)
    is Some(_),
  )
  invalid_standby["standby_workers"] = "-1"
  assert_true(
    @protocol.validate_config(config_schema(options), invalid_standby)
    is Some(_),
  )
  defaults["instance_type"] = "p5.48xlarge"
  assert_true(
    @protocol.validate_config(config_schema(options), defaults) is Some(_),
  )
  let docker = { ..options, mode: "docker", }
  assert_eq(config_schema(docker).length(), 3)
  assert_eq(
    @protocol.validate_config(config_schema(docker), config_defaults(docker)),
    None,
  )
  let on_demand = { ..options, spot_asg: "", }
  let config = config_defaults(on_demand)
  config["purchase_policy"] = "spot-with-on-demand-fallback"
  assert_true(
    @protocol.validate_config(config_schema(on_demand), config) is Some(_),
  )
}

///|
test "ASG capacity counts busy tasks and queued jobs, respects cap and pause" {
  let options = managed_test_options()
  let config = config_defaults(options)
  config["max_workers"] = "3"
  let busy : @protocol.WorkerView = {
    id: "1",
    key: "i-example",
    state: "busy",
    draining: false,
    applied_revision: "1",
    last_seen_ms: "1",
    idle_since_ms: "1",
    active_attempts: 1,
  }
  let snapshot : @protocol.ProviderSnapshot = {
    version: 1,
    id: "1",
    mode: "asg",
    paused: false,
    config_revision: "1",
    schema: config_schema(options),
    config,
    queued_jobs: 1,
    workers: [busy],
  }
  assert_eq(desired_workers(snapshot), 2)
  assert_eq(desired_workers({ ..snapshot, queued_jobs: 10, }), 3)
  assert_eq(desired_workers({ ..snapshot, paused: true, }), 0)
  assert_eq(desired_workers({ ..snapshot, workers: [], queued_jobs: 0, }), 0)
  config["standby_workers"] = "1"
  assert_eq(desired_workers({ ..snapshot, workers: [], queued_jobs: 0, }), 1)
  assert_eq(desired_workers({ ..snapshot, queued_jobs: 0, }), 2)
  assert_eq(desired_workers(snapshot), 3)
  assert_eq(desired_workers({ ..snapshot, queued_jobs: 10, }), 3)
  assert_eq(desired_workers({ ..snapshot, paused: true, }), 0)
  config["standby_workers"] = "20"
  assert_eq(desired_workers({ ..snapshot, workers: [], queued_jobs: 0, }), 3)
}

///|
test "Windows ASG bootstrap uses PowerShell and keeps credentials out of history" {
  let (document, command) = worker_bootstrap_command(
    "us-west-2", "/moonhub-runner/windows/i-example", "windows",
  )
  assert_eq(document, "AWS-RunPowerShellScript")
  assert_true(command.contains("--with-decryption"))
  assert_true(command.contains("icacls.exe"))
  assert_true(command.contains("New-ScheduledTaskAction"))
  assert_true(command.contains("-MultipleInstances IgnoreNew"))
  assert_true(command.contains("-User 'SYSTEM'"))
  assert_true(!command.contains("systemd"))
  let (document, command) = worker_bootstrap_command(
    "us-west-2", "/moonhub-runner/linux/i-example", "linux",
  )
  assert_eq(document, "AWS-RunShellScript")
  assert_true(command.contains("systemd-run"))
}

///|
test "AMI platform is optional for Linux and explicit for Windows" {
  let linux : Array[WorkerImage] = @json.from_json(
    @json.parse("[{\"architecture\":\"x86_64\",\"platform\":null}]"),
  )
  assert_eq(linux[0].architecture, "x86_64")
  assert_eq(linux[0].platform, None)
  let windows : Array[WorkerImage] = @json.from_json(
    @json.parse("[{\"architecture\":\"x86_64\",\"platform\":\"windows\"}]"),
  )
  assert_eq(windows[0].platform, Some("windows"))
}
