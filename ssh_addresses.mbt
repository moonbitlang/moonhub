///|
struct SshEndpoint {
  host : String
  port : UInt16
} derive(Eq, Debug)

///|
struct SshAddressConfig {
  public_override : SshEndpoint?
  internal : SshEndpoint?
}

///|
let no_ssh_address_config : SshAddressConfig = {
  public_override: None,
  internal: None,
}

///|
extenum @moonback.TypedBox += {
  SshAddresses(SshAddressConfig)
}

///|
let config_ssh_addresses : @moonback.TypedKey[SshAddressConfig] = TypedKey(
  name="moonhub.ssh_addresses",
  box=value => SshAddresses(value),
  unbox=value => {
    match value {
      SshAddresses(config) => Some(config)
      _ => None
    }
  },
)

///|
fn SshEndpoint::from_fields(
  raw_host : String,
  raw_port : String,
) -> SshEndpoint raise {
  let host = raw_host.trim().to_owned().to_lower()
  let port_text = raw_port.trim().to_owned()
  guard port_text.length() <= 5 && parse_port(port_text) is Some(port) else {
    raise BadRequest(message="SSH port must be between 1 and 65535")
  }
  let host = if host.has_prefix("[") && host.has_suffix("]") {
    host[1:host.length() - 1].to_owned()
  } else {
    host
  }
  guard !host.is_empty() && !host.contains("%") else {
    raise BadRequest(message="enter a hostname or IP address")
  }
  let host = if host.contains(":") {
    let address = @socket.Addr::parse("[\{host}]:1") catch {
      _ => raise BadRequest(message="invalid IPv6 address")
    }
    let canonical = address.to_string()
    guard address.is_ipv6() else {
      raise BadRequest(message="invalid IPv6 address")
    }
    canonical[1:canonical.length() - 3].to_owned()
  } else {
    guard valid_ssh_host(host) else {
      raise BadRequest(
        message="enter a hostname or IP address, without a scheme or path",
      )
    }
    let numeric = host.iter().all(ch => ch.is_ascii_digit() || ch == '.')
    if numeric {
      let address = @socket.Addr::parse("\{host}:1") catch {
        _ => raise BadRequest(message="invalid IPv4 address")
      }
      address.to_string().strip_suffix(":1").unwrap().to_owned()
    } else {
      host
    }
  }
  guard host != "0.0.0.0" && host != "::" else {
    raise BadRequest(
      message="use a reachable SSH host, not a wildcard listen address",
    )
  }
  { host, port, }
}

///|
fn SshEndpoint::from_authority(authority : String) -> SshEndpoint raise {
  if authority.has_prefix("[") {
    guard authority.split_once("]") is Some((host, tail)) else {
      raise BadRequest(message="invalid SSH authority")
    }
    guard host.contains(":") else {
      raise BadRequest(message="brackets require an IPv6 address")
    }
    let port = if tail.is_empty() {
      "22"
    } else {
      guard tail.strip_prefix(":") is Some(port) else {
        raise BadRequest(message="invalid SSH authority")
      }
      port.to_owned()
    }
    SshEndpoint::from_fields(host[1:].to_owned(), port)
  } else {
    match authority.split_once(":") {
      Some((host, port)) =>
        SshEndpoint::from_fields(host.to_owned(), port.to_owned())
      None => SshEndpoint::from_fields(authority, "22")
    }
  }
}

///|
fn SshEndpoint::from_url(value : String) -> SshEndpoint raise {
  let value = value.trim().strip_suffix("/").unwrap_or(value.trim())
  guard value.strip_prefix("ssh://git@") is Some(authority) &&
    !authority.contains("/") else {
    raise BadRequest(
      message="SSH endpoint must be ssh://git@host[:port], without a repository path",
    )
  }
  SshEndpoint::from_authority(authority.to_owned())
}

///|
fn SshEndpoint::authority(self : SshEndpoint) -> String {
  if self.host.contains(":") {
    "[\{self.host}]:\{self.port}"
  } else {
    "\{self.host}:\{self.port}"
  }
}

///|
let uri_segment_escape_chars : String = @percent.non_alphanumeric
  .replace_all(old="-", new="")
  .replace_all(old=".", new="")
  .replace_all(old="_", new="")
  .replace_all(old="~", new="")

///|
fn SshEndpoint::clone_url(self : SshEndpoint, repo : RepoId) -> String {
  let owner = @percent.encode(repo.owner, escape_chars=uri_segment_escape_chars)
  let name = @percent.encode(repo.name, escape_chars=uri_segment_escape_chars)
  "ssh://git@\{self.authority()}/\{owner}/\{name}.git"
}

///|
fn ssh_address_config_from_env() -> SshAddressConfig raise {
  {
    public_override: env_value("MOONHUB_SSH_PUBLIC_URL").map(
      SshEndpoint::from_url,
    ),
    internal: env_value("MOONHUB_SSH_INTERNAL_URL").map(SshEndpoint::from_url),
  }
}

///|
fn effective_ssh_endpoint(
  pool : Database,
  config : SshAddressConfig,
) -> SshEndpoint? raise {
  if config.public_override is Some(endpoint) {
    return Some(endpoint)
  }
  pool.with_client(client => {
    let row = client.query_opt(
      "SELECT ssh_public_host, ssh_public_port FROM site_settings WHERE id = 1",
    )
    guard row is Some(row) else { return None }
    let host : String = row.get_name("ssh_public_host")
    let port : Int64 = row.get_name("ssh_public_port")
    Some(SshEndpoint::from_fields(host, port.to_string()))
  })
}

///|
fn save_ssh_endpoint(
  pool : Database,
  actor : CurrentUser,
  config : SshAddressConfig,
  host : String,
  port : String,
) -> Unit raise {
  guard actor.is_site_admin else {
    raise Forbidden(message="site administrator required")
  }
  guard config.public_override is None else {
    raise Forbidden(
      message="SSH address is managed by deployment configuration",
    )
  }
  let endpoint = SshEndpoint::from_fields(host, port)
  pool.with_client(client => {
    let _ = client.execute(
      (
        #|INSERT INTO site_settings (id, ssh_public_host, ssh_public_port, updated_by_user_id)
        #|VALUES (1, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET
        #|  ssh_public_host = excluded.ssh_public_host, ssh_public_port = excluded.ssh_public_port,
        #|  updated_by_user_id = excluded.updated_by_user_id, updated_at = datetime('now')
      ),
      params=[endpoint.host, endpoint.port.to_int().to_int64(), actor.id],
    )
  })
}
