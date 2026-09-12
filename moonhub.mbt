///|
fn parse_port(s : String) -> UInt16? {
  let mut n = 0
  for ch in s {
    if ch < '0' || ch > '9' {
      return None
    }
    n = n * 10 + ch.to_int() - '0'.to_int()
  }
  if n > 0 && n <= 65535 {
    Some(n.to_uint16())
  } else {
    None
  }
}

///|
fn single_value(matches : @argparse.Matches, name : String) -> String? {
  match matches.values.get(name) {
    Some(values) => values.get(0)
    None => None
  }
}

///|
async fn parse_config() -> Config {
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
  let port = match parse_port(port_text) {
    Some(port) => port
    None => abort("invalid --port: \{port_text}")
  }
  if !valid_name_key(root_user_name_key) {
    abort("invalid --root-user: \{root_user_name_key}")
  }
  if root_user_initial_password.is_empty() {
    raise BadRequest(
      message="--root-password or --root-password-file is required",
    )
  }
  {
    root: trim_trailing_slash(root),
    assets_root: trim_trailing_slash(assets_root),
    host,
    port,
    root_user: {
      name_key: root_user_name_key,
      initial_password: root_user_initial_password,
    },
  }
}

///|
async fn normalize_config(config : Config) -> Config {
  {
    ..config,
    root: trim_trailing_slash(@fs.realpath(config.root)),
    assets_root: trim_trailing_slash(@fs.realpath(config.assets_root)),
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
  if !is_directory(raw_config.root) {
    abort("repo root is not a directory: \{raw_config.root}")
  }
  if !@fs.exists(raw_config.assets_root) {
    abort("assets root does not exist: \{raw_config.assets_root}")
  }
  if !is_directory(raw_config.assets_root) {
    abort("assets root is not a directory: \{raw_config.assets_root}")
  }
  let config = normalize_config(raw_config)
  serve(config) catch {
    BadRequest(message~) => report_startup_error(message)
    Unauthorized(message~) => report_startup_error(message)
    NotFound(message~) => report_startup_error(message)
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
    Some(
      "ssh-authorized-key"
      | "ssh-serve"
      | "ssh-key-add"
      | "ssh-key-list"
      | "ssh-key-revoke"
      | "repo-create"
    ) => {
      let code = run_management_cli(args[1:]) catch {
        err => {
          @stdio.stderr.write("moonhub: \{err}\n")
          1
        }
      }
      @sys.exit(if code < 0 { 128 - code } else { code })
    }
    _ => {
      load_dotenv(".env")
      run_web() catch {
        err => report_startup_error(err.to_string())
      }
    }
  }
}
