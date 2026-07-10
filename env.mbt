///|
async fn load_dotenv(path : String) -> Unit {
  let text = @fs.read_file(path).text() catch { _ => return }
  for raw_line in text.split("\n") {
    let line = raw_line.trim()
    if line.is_empty() || line.has_prefix("#") {
      continue
    }
    match line.split_once("=") {
      Some((name, value)) =>
        if !name.is_empty() {
          @env.set_env_var(name.to_owned(), value.to_owned())
        }
      None => ()
    }
  }
}

///|
fn parse_pg_url(url : String) -> DbConfig raise AppError {
  let prefix = "postgres://"
  guard url.has_prefix(prefix) else {
    raise BadRequest(message="PG_URL must start with postgres://")
  }
  let rest = url[prefix.length():]
  let (auth, host_db) = match rest.split_once("@") {
    Some(parts) => parts
    None => raise BadRequest(message="PG_URL is missing credentials")
  }
  let (raw_user, raw_password) = match auth.split_once(":") {
    Some(parts) => parts
    None => (auth, "")
  }
  let (host_port, raw_db) = match host_db.split_once("/") {
    Some(parts) => parts
    None => raise BadRequest(message="PG_URL is missing database")
  }
  let (host, port) = match host_port.split_once(":") {
    Some((host, port_text)) =>
      (
        host.to_owned(),
        @string.parse_int(port_text) catch {
          _ => raise BadRequest(message="invalid PG_URL port")
        },
      )
    None => (host_port.to_owned(), 5432)
  }
  {
    host,
    port,
    user: percent_decode(raw_user),
    password: Some(percent_decode(raw_password)),
    name: percent_decode(raw_db),
    pool_size: 8,
  }
}

///|
fn db_config_from_env() -> DbConfig raise AppError {
  match @env.get_env_var("PG_URL") {
    Some(url) => parse_pg_url(url)
    None => raise BadRequest(message="PG_URL is required")
  }
}
