///|
fn provider_cli_int(options : @argparse.Matches, name : String) -> Int raise {
  let value = cli_value(options, name)
  @string.parse_int(value) catch {
    _ => raise @provider.InvalidConfiguration("invalid numeric provider option")
  }
}

///|
async fn run_provider_cli(args : ArrayView[String]) -> Int {
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM])
  let command = @argparse.Command(
    "provider",
    options=[
      OptionArg("server", long="server", env="MOONHUB_SERVER", default_values=[
        "http://web:8080",
      ]),
      OptionArg(
        "token-file",
        long="token-file",
        env="MOONHUB_PROVIDER_TOKEN_FILE",
        default_values=["/run/secrets/provider_token"],
      ),
      OptionArg(
        "runner-server",
        long="runner-server",
        env="MOONHUB_RUNNER_SERVER",
        required=true,
      ),
      OptionArg(
        "runner-image",
        long="runner-image",
        env="MOONHUB_RUNNER_IMAGE",
        required=true,
      ),
      OptionArg("docker", long="docker", env="MOONHUB_DOCKER", default_values=[
        "/usr/bin/docker",
      ]),
      OptionArg("docker-host", long="docker-host", env="DOCKER_HOST", default_values=[
        "unix:///var/run/docker.sock",
      ]),
      OptionArg("network", long="network", env="MOONHUB_RUNNER_NETWORK", default_values=[
        "bridge",
      ]),
      OptionArg("runner-host", long="runner-host", env="MOONHUB_RUNNER_HOST", default_values=[
        "",
      ]),
      OptionArg(
        "runner-host-ip",
        long="runner-host-ip",
        env="MOONHUB_RUNNER_HOST_IP",
        default_values=[""],
      ),
      OptionArg(
        "workspace-root",
        long="workspace-root",
        env="MOONHUB_PROVIDER_WORKSPACE",
        default_values=["/var/lib/moonhub/provider"],
      ),
      OptionArg("poll-ms", long="poll-ms", env="MOONHUB_PROVIDER_POLL_MS", default_values=[
        "1000",
      ]),
      OptionArg("memory", long="memory", env="MOONHUB_RUNNER_MEMORY", default_values=[
        "512m",
      ]),
      OptionArg("cpus", long="cpus", env="MOONHUB_RUNNER_CPUS", default_values=[
        "1",
      ]),
      OptionArg(
        "pids-limit",
        long="pids-limit",
        env="MOONHUB_RUNNER_PIDS_LIMIT",
        default_values=["256"],
      ),
    ],
    flags=[FlagArg("allow-http", long="allow-http", env="MOONHUB_ALLOW_HTTP")],
    about="Claim and execute one-job pipeline assignments in disposable Docker containers.",
  )
  let options = command.parse(argv=args, env=@env.get_env_vars())
  let token_path = cli_value(options, "token-file")
  guard @fs.kind(token_path, follow_symlink=false) is Regular &&
    @fs.file_size(token_path) <= 256L else {
    raise @provider.InvalidConfiguration(
      "provider token file must be a regular small file",
    )
  }
  let token = @fs.read_file(token_path).text().trim().to_owned()
  @provider.run(
    {
      server: cli_value(options, "server"),
      runner_server: cli_value(options, "runner-server"),
      runner_image: cli_value(options, "runner-image"),
      docker: cli_value(options, "docker"),
      docker_host: cli_value(options, "docker-host"),
      network: cli_value(options, "network"),
      runner_host: cli_value(options, "runner-host"),
      runner_host_ip: cli_value(options, "runner-host-ip"),
      workspace_root: cli_value(options, "workspace-root"),
      poll_ms: provider_cli_int(options, "poll-ms"),
      allow_http: options.flags.get("allow-http").unwrap_or(false),
      memory: cli_value(options, "memory"),
      cpus: cli_value(options, "cpus"),
      pids_limit: provider_cli_int(options, "pids-limit"),
    },
    token,
  )
  0
}
