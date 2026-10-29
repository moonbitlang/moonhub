///|
pub(all) struct MirrorConfig {
  ssh_command : String
  timeout_ms : Int32
  keyscan_command : String
}

///|
pub let default_mirror_config : MirrorConfig = {
  ssh_command: "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null -o \"UserKnownHostsFile=$MOONHUB_MIRROR_KNOWN_HOSTS\" -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o ForwardAgent=no -o ClearAllForwardings=yes -o RequestTTY=no -i \"$MOONHUB_MIRROR_IDENTITY\"",
  timeout_ms: 300000,
  keyscan_command: "/usr/bin/ssh-keyscan",
}

///|
pub fn mirror_config_from_env() -> MirrorConfig raise {
  let seconds = match @config.env_value("MOONHUB_MIRROR_TIMEOUT_SECONDS") {
    None => 300
    Some(value) =>
      @string.parse_int(value) catch {
        _ => raise @domain.BadRequest(message="invalid mirror timeout")
      }
  }
  guard seconds >= 1 && seconds <= 3600 else {
    raise @domain.BadRequest(message="mirror timeout must be 1 to 3600 seconds")
  }
  {
    ssh_command: @config.env_value("MOONHUB_MIRROR_SSH_COMMAND").unwrap_or(
      default_mirror_config.ssh_command,
    ),
    timeout_ms: seconds * 1000,
    keyscan_command: @config.env_value("MOONHUB_MIRROR_KEYSCAN").unwrap_or(
      default_mirror_config.keyscan_command,
    ),
  }
}

///|
fn normalize_mirror_host_keys(value : String) -> String raise {
  guard value.length() <= 16384 else {
    raise @domain.BadRequest(
      message="Destination host keys must be at most 16384 characters",
    )
  }
  let keys : Array[String] = []
  for line in value.split("\n") {
    let line = line.trim()
    if line.is_empty() {
      continue
    }
    let fields = line
      .replace(old="\t", new=" ")
      .split(" ")
      .filter(field => !field.is_empty())
      .collect()
    guard fields.length() >= 2 && fields[0] == "ssh-ed25519" else {
      raise @domain.BadRequest(
        message="Expected an OpenSSH Ed25519 host public key, beginning with ssh-ed25519",
      )
    }
    let bytes = @base64.decode(fields[1]) catch {
      _ =>
        raise @domain.BadRequest(
          message="Invalid destination host public key encoding",
        )
    }
    let prefix = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
    guard bytes.length() == 51 else {
      raise @domain.BadRequest(message="Invalid Ed25519 host public key")
    }
    for i = 0; i < prefix.length(); i = i + 1 {
      guard bytes[i] == prefix[i] else {
        raise @domain.BadRequest(message="Invalid Ed25519 host public key")
      }
    }
    let normalized = "ssh-ed25519 \{@base64.encode(bytes)}"
    if !keys.contains(normalized) {
      keys.push(normalized)
    }
    guard keys.length() <= 16 else {
      raise @domain.BadRequest(
        message="Configure at most 16 destination host keys per mirror",
      )
    }
  }
  keys.join("\n")
}

///|
fn mirror_known_hosts(
  target : SshImportSource,
  host_keys : String,
) -> String raise {
  let keys = normalize_mirror_host_keys(host_keys)
  guard !keys.is_empty() else {
    raise @domain.BadRequest(
      message="Initialize the destination and confirm its SSH host fingerprint before enabling automatic sync",
    )
  }
  let host = if target.port == 22 {
    target.host
  } else {
    "[\{target.host}]:\{target.port}"
  }
  keys.split("\n").map(key => "\{host} \{key}\n").join("")
}
