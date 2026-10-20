///|
fn single_value(matches : @argparse.Matches, name : String) -> String? {
  match matches.values.get(name) {
    Some(values) => values.get(0)
    None => None
  }
}

///|
async fn parse_config() -> @web.Config {
  let cmd = @argparse.Command(
    "moonhub",
    about="Serve registered bare Git repositories. Administrative commands: ssh-key-add, ssh-key-list, ssh-key-revoke, repo-create (use COMMAND --help).",
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
  let matches = cmd.parse(env=@env.get_env_vars())
  let root = single_value(matches, "root").unwrap_or("")
  let assets_root = single_value(matches, "assets").unwrap_or("")
  let host = single_value(matches, "host").unwrap_or("127.0.0.1")
  let port_text = single_value(matches, "port").unwrap_or("8080")
  let root_user_name_key = single_value(matches, "root-user").unwrap_or("root")
  let root_user_initial_password = match
    single_value(matches, "root-password-file") {
    Some(path) => @fs.read_file(path).text().trim().to_owned()
    None => single_value(matches, "root-password").unwrap_or("")
  }
  let port = match @config.parse_port(port_text) {
    Some(port) => port
    None => abort("invalid --port: \{port_text}")
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
async fn run_web() -> Unit {
  let raw_config = parse_config()
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
async fn main {
  let args = @env.args()
  match args.get(1) {
    Some("auth" | "mr" | "issue" | "ci" | "inbox" | "attachment" | "webhook") => {
      let code = @cli.run(args[1:]) catch {
        @cli.Invalid(message) => {
          @stdio.stderr.write("moonhub: \{message}\n")
          2
        }
        @cli.InvalidResponse => {
          @stdio.stderr.write("moonhub: invalid API JSON response\n")
          1
        }
        @cli.TimedOut => {
          @stdio.stderr.write("moonhub: API request timed out\n")
          1
        }
        @cli.Rejected(status, message) => {
          @stdio.stderr.write(
            "moonhub: HTTP \{status}: \{@cli.terminal_text(message)}\n",
          )
          1
        }
        _ => {
          @stdio.stderr.write("moonhub: CLI request failed\n")
          1
        }
      }
      @sys.exit(code)
    }
    Some("runner") => {
      let code = run_runner_cli(args[2:]) catch {
        @runner.InvalidConfiguration(message) => {
          @stdio.stderr.write("runner: \{message}\n")
          2
        }
        _ => {
          @stdio.stderr.write("runner: execution failed or was interrupted\n")
          2
        }
      }
      @sys.exit(code)
    }
    Some("provider") => {
      let code = run_provider_cli(args[2:]) catch {
        @provider.InvalidConfiguration(message) => {
          @stdio.stderr.write("provider: \{message}\n")
          2
        }
        _ => {
          @stdio.stderr.write("provider: execution failed or was interrupted\n")
          2
        }
      }
      @sys.exit(code)
    }
    Some(
      "ssh-authorized-key"
      | "ssh-serve"
      | "ssh-pre-receive"
      | "ssh-ref-transaction"
      | "ssh-key-add"
      | "ssh-key-list"
      | "ssh-key-revoke"
      | "deploy-key-add"
      | "deploy-key-list"
      | "deploy-key-revoke"
      | "repo-create"
      | "pipeline-provider-create"
      | "pipeline-provider-ensure"
      | "pipeline-rerun"
    ) as command => {
      let code = run_management_cli(args[1:]) catch {
        err => {
          let message = match err {
            @domain.BadRequest(message~)
            | @domain.Unauthorized(message~)
            | @domain.Forbidden(message~)
            | @domain.NotFound(message~)
            | @gitops.Failure(message~) => message
            _ =>
              if command == Some("ssh-serve") ||
                command == Some("ssh-pre-receive") ||
                command == Some("ssh-ref-transaction") {
                @domain.internal_error_message
              } else {
                err.to_string()
              }
          }
          @stdio.stderr.write("moonhub: \{message}\n")
          1
        }
      }
      @sys.exit(if code < 0 { 128 - code } else { code })
    }
    _ => {
      @config.load_dotenv(".env")
      run_web() catch {
        err => report_startup_error(err.to_string())
      }
    }
  }
}
