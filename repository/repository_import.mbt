///|
pub struct SshImportSource {
  url : String
  host : String
  port : UInt16
  user : String
  path : String
}

///|
pub(all) struct RepoImportConfig {
  credentials_root : String
  ssh_wrapper : String
  timeout_ms : Int32
}

///|
struct TeamImportCredentials {
  identity : String
  known_hosts : String
  allowed_hosts : Array[String]
}

///|
pub fn repo_import_config_from_env() -> RepoImportConfig? raise {
  guard @config.env_value("MOONHUB_SSH_IMPORT_ROOT") is Some(root) else {
    return None
  }
  let timeout = match @config.env_value("MOONHUB_IMPORT_TIMEOUT_SECONDS") {
    None => 300
    Some(value) =>
      @string.parse_int(value) catch {
        _ => raise @domain.BadRequest(message="invalid import timeout")
      }
  }
  guard timeout >= 1 && timeout <= 3600 else {
    raise @domain.BadRequest(message="import timeout must be 1 to 3600 seconds")
  }
  Some({
    credentials_root: root,
    ssh_wrapper: @config.env_value("MOONHUB_IMPORT_SSH").unwrap_or(
      "/usr/local/bin/moonhub-import-ssh",
    ),
    timeout_ms: timeout * 1000,
  })
}

///|
fn valid_ssh_host(host : String) -> Bool {
  guard !host.is_empty() && host.length() <= 253 else { return false }
  for label in host.split(".") {
    guard !label.is_empty() &&
      label.length() <= 63 &&
      !label.has_prefix("-") &&
      !label.has_suffix("-") else {
      return false
    }
    for ch in label {
      guard ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '-' else {
        return false
      }
    }
  }
  true
}

///|
fn parse_ssh_import_source(value : String) -> SshImportSource raise {
  guard !value.is_empty() && value.length() <= 2048 else {
    raise @domain.BadRequest(message="invalid SSH source URL")
  }
  let (authority, path, explicit_port) = if value.strip_prefix("ssh://")
    is Some(rest) {
    guard rest.split_once("/") is Some((authority, path)) else {
      raise @domain.BadRequest(message="SSH URL must include a repository path")
    }
    (authority.to_owned(), path.to_owned(), true)
  } else {
    guard !value.contains("://") &&
      value.split_once(":") is Some((authority, path)) else {
      raise @domain.BadRequest(message="use an ssh:// URL or user@host:path")
    }
    (authority.to_owned(), path.to_owned(), false)
  }
  guard authority.split_once("@") is Some((user, server)) else {
    raise @domain.BadRequest(message="SSH URL must include a username")
  }
  guard !user.is_empty() && user.length() <= 64 && !user.has_prefix("-") else {
    raise @domain.BadRequest(message="invalid SSH username")
  }
  for ch in user {
    guard ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ch == '_' ||
      ch == '-' else {
      raise @domain.BadRequest(message="invalid SSH username")
    }
  }
  let endpoint = if explicit_port {
    SshEndpoint::from_authority(server.to_owned())
  } else {
    SshEndpoint::from_fields(server.to_owned(), "22")
  }
  guard !path.is_empty() && !path.has_prefix("/") else {
    raise @domain.BadRequest(message="invalid remote repository path")
  }
  for segment in path.split("/") {
    guard !segment.is_empty() &&
      segment != "." &&
      segment != ".." &&
      !segment.has_prefix("-") else {
      raise @domain.BadRequest(message="invalid remote repository path")
    }
    for ch in segment {
      guard ch.is_ascii_alphabetic() ||
        ch.is_ascii_digit() ||
        ch == '-' ||
        ch == '_' ||
        ch == '.' else {
        raise @domain.BadRequest(message="invalid remote repository path")
      }
    }
  }
  {
    url: if explicit_port {
      "ssh://\{user}@\{endpoint.authority()}/\{path}"
    } else {
      "\{user}@\{endpoint.host}:\{path}"
    },
    host: endpoint.host,
    port: endpoint.port,
    user: user.to_owned(),
    path,
  }
}

///|
pub async fn team_import_credentials(
  config : RepoImportConfig,
  owner : String,
  identity_required~ : Bool = true,
) -> TeamImportCredentials {
  guard @domain.valid_name_key(owner) else {
    raise @domain.BadRequest(message="invalid import namespace")
  }
  let root = @domain.trim_trailing_slash(@fs.realpath(config.credentials_root))
  let directory = "\{root}/\{owner}"
  guard @fs.realpath(directory) == directory else {
    raise @domain.BadRequest(message="invalid SSH import credentials directory")
  }
  let files = ["known_hosts", "allowed_hosts"]
  if identity_required {
    files.push("id_ed25519")
  }
  for file in files {
    guard @fs.kind("\{directory}/\{file}", follow_symlink=false) is Regular else {
      raise @domain.BadRequest(
        message="SSH import credential files must be regular files",
      )
    }
  }
  let allowed = @fs.read_file("\{directory}/allowed_hosts").text()
  let hosts : Array[String] = []
  for line in allowed.split("\n") {
    let line = line.trim()
    if !line.is_empty() && !line.has_prefix("#") {
      hosts.push(line.to_owned())
    }
  }
  guard !hosts.is_empty() else {
    raise @domain.BadRequest(
      message="no SSH source hosts are allowed for this team",
    )
  }
  {
    identity: "\{directory}/id_ed25519",
    known_hosts: "\{directory}/known_hosts",
    allowed_hosts: hosts,
  }
}

///|
pub fn authorize_import_source(
  credentials : TeamImportCredentials,
  source : SshImportSource,
) -> Unit raise {
  let endpoint : SshEndpoint = { host: source.host, port: source.port, }
  guard credentials.allowed_hosts.contains(endpoint.authority()) else {
    raise @domain.BadRequest(
      message="this SSH source host and port are not allowed for the team",
    )
  }
}
