///|
struct SshImportSource {
  url : String
  host : String
  port : UInt16
  user : String
  path : String
}

///|
struct RepoImportConfig {
  credentials_root : String
  ssh_wrapper : String
  timeout_ms : Int
}

///|
struct TeamImportCredentials {
  identity : String
  known_hosts : String
  allowed_hosts : Array[String]
}

///|
extenum @moonback.TypedBox += {
  RepositoryImportConfig(RepoImportConfig)
}

///|
let config_repo_import : @moonback.TypedKey[RepoImportConfig] = TypedKey(
  name="moonhub.repo_import",
  box=config => RepositoryImportConfig(config),
  unbox=value => {
    match value {
      RepositoryImportConfig(config) => Some(config)
      _ => None
    }
  },
)

///|
fn repo_import_config_from_env() -> RepoImportConfig? raise {
  guard env_value("MOONHUB_SSH_IMPORT_ROOT") is Some(root) else { return None }
  let timeout = match env_value("MOONHUB_IMPORT_TIMEOUT_SECONDS") {
    None => 300
    Some(value) =>
      @string.parse_int(value) catch {
        _ => raise BadRequest(message="invalid import timeout")
      }
  }
  guard timeout >= 1 && timeout <= 3600 else {
    raise BadRequest(message="import timeout must be 1 to 3600 seconds")
  }
  Some({
    credentials_root: root,
    ssh_wrapper: env_value("MOONHUB_IMPORT_SSH").unwrap_or(
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
    raise BadRequest(message="invalid SSH source URL")
  }
  let (authority, path, explicit_port) = if value.strip_prefix("ssh://")
    is Some(rest) {
    guard rest.split_once("/") is Some((authority, path)) else {
      raise BadRequest(message="SSH URL must include a repository path")
    }
    (authority.to_owned(), path.to_owned(), true)
  } else {
    guard !value.contains("://") &&
      value.split_once(":") is Some((authority, path)) else {
      raise BadRequest(message="use an ssh:// URL or user@host:path")
    }
    (authority.to_owned(), path.to_owned(), false)
  }
  guard authority.split_once("@") is Some((user, server)) else {
    raise BadRequest(message="SSH URL must include a username")
  }
  guard !user.is_empty() && user.length() <= 64 && !user.has_prefix("-") else {
    raise BadRequest(message="invalid SSH username")
  }
  for ch in user {
    guard ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ch == '_' ||
      ch == '-' else {
      raise BadRequest(message="invalid SSH username")
    }
  }
  let endpoint = if explicit_port {
    SshEndpoint::from_authority(server.to_owned())
  } else {
    SshEndpoint::from_fields(server.to_owned(), "22")
  }
  guard !path.is_empty() && !path.has_prefix("/") else {
    raise BadRequest(message="invalid remote repository path")
  }
  for segment in path.split("/") {
    guard !segment.is_empty() &&
      segment != "." &&
      segment != ".." &&
      !segment.has_prefix("-") else {
      raise BadRequest(message="invalid remote repository path")
    }
    for ch in segment {
      guard ch.is_ascii_alphabetic() ||
        ch.is_ascii_digit() ||
        ch == '-' ||
        ch == '_' ||
        ch == '.' else {
        raise BadRequest(message="invalid remote repository path")
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
async fn team_import_credentials(
  config : RepoImportConfig,
  owner : String,
) -> TeamImportCredentials {
  guard valid_name_key(owner) else {
    raise BadRequest(message="invalid import namespace")
  }
  let root = trim_trailing_slash(@fs.realpath(config.credentials_root))
  let directory = "\{root}/\{owner}"
  guard @fs.realpath(directory) == directory else {
    raise BadRequest(message="invalid SSH import credentials directory")
  }
  for file in ["id_ed25519", "known_hosts", "allowed_hosts"] {
    guard @fs.kind("\{directory}/\{file}", follow_symlink=false) is Regular else {
      raise BadRequest(
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
    raise BadRequest(message="no SSH source hosts are allowed for this team")
  }
  {
    identity: "\{directory}/id_ed25519",
    known_hosts: "\{directory}/known_hosts",
    allowed_hosts: hosts,
  }
}

///|
fn authorize_import_source(
  credentials : TeamImportCredentials,
  source : SshImportSource,
) -> Unit raise {
  let endpoint : SshEndpoint = { host: source.host, port: source.port, }
  guard credentials.allowed_hosts.contains(endpoint.authority()) else {
    raise BadRequest(
      message="this SSH source host and port are not allowed for the team",
    )
  }
}
