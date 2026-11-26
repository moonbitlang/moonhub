///|
fn single_value(matches : @argparse.Matches, name : String) -> String? {
  matches.values.get(name).bind(values => values.get(0))
}

///|
fn serve_command() -> @argparse.Command {
  @argparse.Command(
    "serve",
    about="Serve registered bare Git repositories and the Web UI (the default command).",
    options=[
      OptionArg("host", long="host", about="Bind host.", default_values=[
        "127.0.0.1",
      ]),
      OptionArg("port", long="port", about="Bind port.", default_values=["8080"]),
      OptionArg(
        "assets",
        long="assets",
        about="Assets directory containing the Vite manifest and browser bundles.",
        required=true,
      ),
      OptionArg(
        "root-user",
        long="root-user",
        env="MOONHUB_ROOT_USER",
        about="Root user name_key created through an invitation.",
        default_values=["root"],
      ),
      OptionArg(
        "root-password",
        long="root-password",
        env="MOONHUB_ROOT_PASSWORD",
        about="Initial one-time password for the root invitation.",
        conflicts_with=["root-password-file"],
      ),
      OptionArg(
        "root-password-file",
        long="root-password-file",
        env="MOONHUB_ROOT_PASSWORD_FILE",
        about="Read the initial root password from a secret file.",
        conflicts_with=["root-password"],
      ),
    ],
    positionals=[
      PositionArg(
        "root",
        about="Repository root containing user_or_org/repo.git directories.",
      ),
    ],
  )
}

///|
fn config_check_command(name : String, about : String) -> @argparse.Command {
  @argparse.Command(name, about~, positionals=[
    PositionArg(
      "config",
      about="Configuration file to validate.",
      num_args=@argparse.ValueRange::single(),
    ),
  ])
}

///|
/// One command tree for the full native executable. Without a command it
/// serves the Web UI, so `moonhub ROOT --assets DIR` keeps working.
fn moonhub_command() -> @argparse.Command {
  @argparse.Command(
    "moonhub",
    about="MoonHub server, administration and collaboration client.\n" +
      "Without a command, serves the Web UI (see serve --help). Client commands\n" +
      "call a MoonHub server; administrative commands open the service database.",
    version=@cli.CLI_VERSION,
    default_subcommand="serve",
    subcommands=[serve_command()] +
      @cli.client_group_commands() +
      management_commands() +
      [
        @runner_cli.command(),
        provider_command(),
        config_check_command(
          "storage-check", "Validate a blob storage configuration file.",
        ),
        config_check_command(
          "oidc-check", "Validate a workflow OIDC issuer configuration file.",
        ),
      ],
  )
}

///|
async fn parse_config(matches : @argparse.Matches) -> @web.Config {
  let root = single_value(matches, "root").unwrap_or("")
  let assets_root = single_value(matches, "assets").unwrap_or("")
  let host = single_value(matches, "host").unwrap_or("127.0.0.1")
  let port_text = single_value(matches, "port").unwrap_or("8080")
  let root_user_name_key = single_value(matches, "root-user").unwrap_or("root")
  let root_user_initial_password = if single_value(
      matches, "root-password-file",
    )
    is Some(path) {
    @fs.read_file(path).text().trim().to_owned()
  } else {
    single_value(matches, "root-password").unwrap_or("")
  }
  guard @config.parse_port(port_text) is Some(port) else {
    abort("invalid --port: \{port_text}")
  }
  if !@domain.valid_name_key(root_user_name_key) {
    abort("invalid --root-user: \{root_user_name_key}")
  }
  if root_user_initial_password.is_empty() {
    raise @domain.BadRequest(
      message="--root-password or --root-password-file is required",
    )
  }
  {
    root: @domain.trim_trailing_slash(root),
    assets_root: @domain.trim_trailing_slash(assets_root),
    host,
    port,
    root_user: {
      name_key: root_user_name_key,
      initial_password: root_user_initial_password,
    },
  }
}

///|
async fn normalize_config(config : @web.Config) -> @web.Config {
  {
    ..config,
    root: @domain.trim_trailing_slash(@fs.realpath(config.root)),
    assets_root: @domain.trim_trailing_slash(@fs.realpath(config.assets_root)),
  }
}

///|
async fn report_startup_error(message : String) -> Unit {
  @stdio.stderr.write("moonhub: \{message}\n")
  @sys.exit(1)
}

///|
async fn run_web(matches : @argparse.Matches) -> Unit {
  let raw_config = parse_config(matches)
  if !@fs.exists(raw_config.root) {
    abort("repo root does not exist: \{raw_config.root}")
  }
  if !@gitops.is_directory(raw_config.root) {
    abort("repo root is not a directory: \{raw_config.root}")
  }
  if !@fs.exists(raw_config.assets_root) {
    abort("assets root does not exist: \{raw_config.assets_root}")
  }
  if !@gitops.is_directory(raw_config.assets_root) {
    abort("assets root is not a directory: \{raw_config.assets_root}")
  }
  let config = normalize_config(raw_config)
  @web.serve(config) catch {
    @domain.BadRequest(message~) => report_startup_error(message)
    @domain.Unauthorized(message~) => report_startup_error(message)
    @domain.NotFound(message~) => report_startup_error(message)
    @moondb.ConnectError(message) =>
      report_startup_error("database error: \{message}")
    @moondb.QueryError(message) =>
      report_startup_error("database error: \{message}")
    @moondb.TypeError(message) =>
      report_startup_error("database error: \{message}")
    @moondb.Closed => report_startup_error("database connection is closed")
    err => raise err
  }
}

///|
/// Run a parsed non-Web command and return its exit code.
async fn run_command(name : String, options : @argparse.Matches) -> Int32 {
  match name {
    "storage-check" =>
      try {
        ignore(
          @storage.Config::load(
            single_value(options, "config").unwrap_or(""),
            node=@config.env_value("MOONHUB_STORAGE_NODE").unwrap_or("node"),
            helper=@config.env_value("MOONHUB_S3_HELPER").unwrap_or(
              "storage/s3/bridge.mjs",
            ),
          ),
        )
        println("Blob storage configuration valid")
        0
      } catch {
        _ => {
          @stdio.stderr.write("moonhub: invalid blob storage configuration\n")
          2
        }
      }
    "oidc-check" =>
      try {
        ignore(
          @oidc.OidcIssuer::load(single_value(options, "config").unwrap_or("")),
        )
        println("Workflow OIDC configuration valid")
        0
      } catch {
        _ => {
          @stdio.stderr.write("moonhub: invalid workflow OIDC configuration\n")
          2
        }
      }
    "runner" =>
      @runner_cli.execute_matches(options) catch {
        @runner.InvalidConfiguration(message) => {
          @stdio.stderr.write("runner: \{message}\n")
          2
        }
        _ => {
          @stdio.stderr.write("runner: execution failed or was interrupted\n")
          2
        }
      }
    "provider" =>
      run_provider(options) catch {
        @provider.InvalidConfiguration(message) => {
          @stdio.stderr.write("provider: \{message}\n")
          2
        }
        _ => {
          @stdio.stderr.write("provider: execution failed or was interrupted\n")
          2
        }
      }
    _ if @cli.is_client_command(name) => @cli.execute_group(name, options)
    _ => {
      let code = run_management(name, options) catch {
        err => {
          let message = match err {
            @domain.BadRequest(message~)
            | @domain.Unauthorized(message~)
            | @domain.Forbidden(message~)
            | @domain.NotFound(message~)
            | @gitops.Failure(message~) => message
            _ =>
              if name
                is ("ssh-serve" | "ssh-pre-receive" | "ssh-ref-transaction") {
                @domain.internal_error_message
              } else {
                err.to_string()
              }
          }
          @stdio.stderr.write("moonhub: \{message}\n")
          1
        }
      }
      if code < 0 {
        128 - code
      } else {
        code
      }
    }
  }
}

///|
async fn main {
  let args = @env.args()
  let argv = args[1:]
  let matches = match
    moonhub_command().parse_outcome(argv~, env=@env.get_env_vars()) {
    Parsed(matches) => matches
    Help(text) => {
      println(@cli.contextual_help(text))
      @sys.exit(0)
      return
    }
    Version(_) => {
      println("moonhub \{@cli.CLI_VERSION}")
      @sys.exit(0)
      return
    }
    Failed(err) => {
      @stdio.stderr.write("moonhub: \{@cli.contextual_help(err.to_string())}\n")
      @sys.exit(2)
      return
    }
  }
  guard matches.subcommand is Some((name, options)) else {
    @sys.exit(2)
    return
  }
  if name == "serve" {
    // The Web service reads `.env` before resolving its environment-backed
    // options; other commands keep using only the process environment.
    @config.load_dotenv(".env")
    guard moonhub_command().parse(argv~, env=@env.get_env_vars()).subcommand
      is Some((_, options)) else {
      return
    }
    run_web(options) catch {
      err => report_startup_error(err.to_string())
    }
  } else {
    @sys.exit(run_command(name, options))
  }
}
