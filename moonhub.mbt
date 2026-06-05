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
fn parse_config() -> Config raise {
  let cmd = @argparse.Command(
    "moonhub",
    about="Serve bare Git repositories from user_or_org/repo.git directories.",
    options=[
      @argparse.OptionArg("host", long="host", about="Bind host.", default_values=[
        "127.0.0.1",
      ]),
      @argparse.OptionArg("port", long="port", about="Bind port.", default_values=[
        "8080",
      ]),
    ],
    positionals=[
      @argparse.PositionArg(
        "root",
        about="Repository root containing user_or_org/repo.git directories.",
      ),
    ],
  )
  let matches = cmd.parse()
  let root = single_value(matches, "root").unwrap_or("")
  let host = single_value(matches, "host").unwrap_or("127.0.0.1")
  let port_text = single_value(matches, "port").unwrap_or("8080")
  let port = match parse_port(port_text) {
    Some(port) => port
    None => abort("invalid --port: " + port_text)
  }
  { root: trim_trailing_slash(root), host, port }
}

///|
async fn main {
  let config = parse_config()
  if !@fs.exists(config.root) {
    abort("repo root does not exist: " + config.root)
  }
  if !is_directory(config.root) {
    abort("repo root is not a directory: " + config.root)
  }
  serve(config)
}
