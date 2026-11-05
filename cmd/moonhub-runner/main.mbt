///|
fn value(options : @argparse.Matches, key : String) -> String {
  options.values.get(key).unwrap()[0]
}

///|
async fn run(args : ArrayView[String]) -> Int32 {
  if args.get(0) == Some("execute") {
    return @runner_cli.execute(args[1:])
  }
  let common = [
    @argparse.OptionArg("runner-server", long="runner-server", default_values=[
      "",
    ]),
    @argparse.OptionArg("docker", long="docker", default_values=[
      if @platform.windows() {
        "docker.exe"
      } else {
        "/usr/bin/docker"
      },
    ]),
    @argparse.OptionArg("docker-host", long="docker-host", env="DOCKER_HOST", default_values=[
      if @platform.windows() {
        "npipe:////./pipe/docker_engine"
      } else {
        "unix:///var/run/docker.sock"
      },
    ]),
    @argparse.OptionArg("workspace-root", long="workspace-root", default_values=[
      if @platform.windows() {
        "C:/ProgramData/MoonHub/workspace"
      } else {
        "/var/lib/moonhub-runner/workspace"
      },
    ]),
    @argparse.OptionArg("network", long="network", default_values=[
      if @platform.windows() {
        "nat"
      } else {
        "bridge"
      },
    ]),
    @argparse.OptionArg("runner-image", long="runner-image", default_values=[
      "moonhub:runner",
    ]),
  ]
  let controller = common.copy()
  controller.append([
    @argparse.OptionArg(
      "server",
      long="server",
      env="MOONHUB_SERVER",
      required=true,
    ),
    @argparse.OptionArg("name", long="name", required=true),
    @argparse.OptionArg("mode", long="mode", required=true),
    @argparse.OptionArg(
      "registration-token-file",
      long="registration-token-file",
      default_values=[""],
    ),
    @argparse.OptionArg("state-dir", long="state-dir", default_values=[
      if @platform.windows() {
        "C:/ProgramData/MoonHub/controller"
      } else {
        "/var/lib/moonhub-runner/controller"
      },
    ]),
    @argparse.OptionArg("tart", long="tart", default_values=[
      "/opt/homebrew/bin/tart",
    ]),
    @argparse.OptionArg("tart-home", long="tart-home", default_values=[
      "/var/lib/moonhub-runner/tart",
    ]),
    @argparse.OptionArg("prepare-timeout", long="prepare-timeout", default_values=[
      "180",
    ]),
    @argparse.OptionArg("aws", long="aws", default_values=["aws"]),
    @argparse.OptionArg("region", long="region", default_values=["us-west-2"]),
    @argparse.OptionArg("asg", long="asg", default_values=[""]),
    @argparse.OptionArg("spot-asg", long="spot-asg", default_values=[""]),
    @argparse.OptionArg("launch-template", long="launch-template", default_values=[
      "",
    ]),
    @argparse.OptionArg("parameter-prefix", long="parameter-prefix", default_values=[
      "/moonhub-runner/ci",
    ]),
    @argparse.OptionArg("instance-types", long="instance-types", default_values=[
      "m6a.large,m7a.large",
    ]),
  ])
  let worker = common.copy()
  worker.push(
    @argparse.OptionArg("bootstrap-file", long="bootstrap-file", required=true),
  )
  let command = @argparse.Command(
    "moonhub-runner",
    about="Independent MoonHub CI controller and isolated task worker.",
    subcommands=[
      @argparse.Command(
        "run",
        about="Register and run a docker, asg or local tart provider.",
        options=controller,
        flags=[@argparse.FlagArg("allow-http", long="allow-http")],
      ),
      @argparse.Command(
        "worker",
        about="Run a worker from a private bootstrap file.",
        options=worker,
      ),
      @argparse.Command(
        "execute",
        about="Execute one leased assignment; use execute --help for options.",
      ),
    ],
  )
  let matches = command.parse(argv=args, env=@env.get_env_vars())
  guard matches.subcommand is Some((subcommand, options)) else { return 0 }
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM, SIGHUP, SIGBREAK])
  let server = if subcommand == "run" {
    value(options, "server")
  } else {
    "https://bootstrap.invalid"
  }
  let base : @provider.Options = {
    server,
    runner_server: if value(options, "runner-server").is_empty() {
      server
    } else {
      value(options, "runner-server")
    },
    runner_image: value(options, "runner-image"),
    docker: value(options, "docker"),
    docker_host: value(options, "docker-host"),
    workspace_root: value(options, "workspace-root"),
    network: value(options, "network"),
    runner_host: "",
    runner_host_ip: "",
    poll_ms: 1000,
    allow_http: options.flags.get("allow-http").unwrap_or(false),
    cpus: "2",
    memory: "4096m",
    pids_limit: 256,
  }
  if subcommand == "worker" {
    @provider.run_bootstrap_worker(value(options, "bootstrap-file"), base)
    return 0
  }
  let prepare_seconds = @protocol.parse_decimal(
    value(options, "prepare-timeout"),
  ).unwrap_or(0L)
  guard prepare_seconds >= 10L && prepare_seconds <= 900L else {
    raise @provider.InvalidConfiguration(
      "prepare-timeout must be 10-900 seconds",
    )
  }
  @provider.run_managed(
    {
      base,
      name: value(options, "name"),
      mode: value(options, "mode"),
      state_dir: value(options, "state-dir"),
      registration_token_file: value(options, "registration-token-file"),
      aws: value(options, "aws"),
      region: value(options, "region"),
      asg: value(options, "asg"),
      spot_asg: value(options, "spot-asg"),
      launch_template: value(options, "launch-template"),
      parameter_prefix: value(options, "parameter-prefix"),
      instance_types: value(options, "instance-types")
      .split(",")
      .map(t => t.trim().to_owned())
      .collect(),
    },
    macos={
      tart: value(options, "tart"),
      home: value(options, "tart-home"),
      prepare_timeout_ms: prepare_seconds.to_int() * 1000,
    },
  )
  0
}

///|
async fn main {
  let args = @env.args()
  let code = run(args[1:]) catch {
    @provider.InvalidConfiguration(message) => {
      @stdio.stderr.write("moonhub-runner: \{message}\n")
      2
    }
    @provider.Rejected(code) => {
      @stdio.stderr.write("moonhub-runner: server rejected request (\{code})\n")
      2
    }
    _ => {
      @stdio.stderr.write(
        "moonhub-runner: operation failed; credentials and task output omitted\n",
      )
      2
    }
  }
  @sys.exit(code)
}
