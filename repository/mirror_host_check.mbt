///|
pub fn mirror_host_fingerprints(host_keys : String) -> Array[String] raise {
  let fingerprints : Array[String] = []
  for key in normalize_mirror_host_keys(host_keys).split("\n") {
    if key.is_empty() {
      continue
    }
    let fields = key.split(" ").collect()
    let bytes = @base64.decode(fields[1])
    fingerprints.push(
      "SHA256:\{@base64.encode(Bytes::from_array(@crypto.sha256(bytes)), padding=false)}",
    )
  }
  fingerprints
}

///|
pub(all) struct MirrorHostCheck {
  challenge : String
  fingerprints : Array[String]
}

///|
async fn scan_mirror_host(
  config : MirrorConfig,
  target : SshImportSource,
) -> String {
  let output = @async.with_timeout(10000, () => {
    @async.with_task_group(group => {
      let (reader, writer) = @process.read_from_process()
      defer reader.close()
      let process = @process.spawn(
        group,
        config.keyscan_command,
        ["-T", "5", "-t", "ed25519", "-p", target.port.to_string(), target.host],
        inherit_env=false,
        extra_env={ "PATH": "/usr/bin:/bin" },
        stdin=@process.redirect_from_file("/dev/null"),
        stdout=writer,
        stderr=@process.redirect_to_file("/dev/null"),
      )
      let buffer = FixedArray::make(16385, b'\x00')
      let mut received = 0
      while received < buffer.length() {
        let count = reader.read(
          buffer,
          offset=received,
          max_len=buffer.length() - received,
        )
        if count == 0 {
          break
        }
        received += count
      }
      guard received < buffer.length() else {
        raise @domain.BadRequest(
          message="Destination returned too many SSH host keys",
        )
      }
      guard process.wait() == 0 else {
        raise @domain.BadRequest(
          message="Could not reach the destination’s SSH server; check the address and try initializing again",
        )
      }
      @utf8.decode(buffer.unsafe_reinterpret_as_bytes()[:received])
    })
  }) catch {
    @domain.BadRequest(_) as err => raise err
    _ =>
      raise @domain.BadRequest(
        message="Could not read the destination’s SSH host key; check the address and try initializing again",
      )
  }
  let keys : Array[String] = []
  let expected = if target.port == 22 {
    target.host
  } else {
    "[\{target.host}]:\{target.port}"
  }
  for line in output.split("\n") {
    let line = line.trim()
    if line.is_empty() || line.has_prefix("#") {
      continue
    }
    let fields = line
      .replace(old="\t", new=" ")
      .split(" ")
      .filter(field => !field.is_empty())
      .collect()
    guard fields.length() == 3 && fields[0] == expected else {
      raise @domain.BadRequest(
        message="Destination returned an unexpected SSH host key; try initializing again",
      )
    }
    keys.push(fields[1].to_owned() + " " + fields[2].to_owned())
  }
  let keys = normalize_mirror_host_keys(keys.join("\n"))
  guard !keys.is_empty() else {
    raise @domain.BadRequest(
      message="Destination did not offer an Ed25519 SSH host key; check the SSH server and try initializing again",
    )
  }
  keys
}

///|
pub async fn initialize_mirror_host(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
  version : Int64,
  config : MirrorConfig,
) -> Unit {
  let scope = require_mirror_manager(pool, actor, repo)
  let lock = mirror_lock(root, id)
  defer lock.close()
  let url : String = pool.with_client(client => {
    guard client.query_opt(
        "SELECT url FROM repository_mirror WHERE id=? AND repository_id=? AND version=? AND active=0",
        params=[id, scope.id, version],
      )
      is Some(row) else {
      raise @domain.BadRequest(
        message="Save this mirror with automatic sync disabled, then initialize its destination",
      )
    }
    row.get_name("url")
  })
  pool.with_client(client => {
    ignore(
      client.execute("DELETE FROM mirror_host_check WHERE mirror_id=?", params=[
        id,
      ]),
    )
  })
  ignore(require_mirror_manager(pool, mirror_actor(pool, actor.id), repo))
  let keys = scan_mirror_host(config, parse_ssh_import_source(url))
  ignore(require_mirror_manager(pool, mirror_actor(pool, actor.id), repo))
  pool.with_client(client => {
    // The mirror lock binds the scan to this saved destination and version.
    ignore(
      client.execute(
        "INSERT INTO mirror_host_check(mirror_id,version,url,challenge,host_keys) VALUES(?,?,?,?,?) ON CONFLICT(mirror_id) DO UPDATE SET version=excluded.version,url=excluded.url,challenge=excluded.challenge,host_keys=excluded.host_keys,created_at=datetime('now')",
        params=[id, version, url, @identity.random_hex(24), keys],
      ),
    )
  })
}

///|
pub async fn confirm_mirror_host(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
  version : Int64,
  challenge : String,
) -> Unit {
  let scope = require_mirror_manager(pool, actor, repo)
  let lock = mirror_lock(root, id)
  defer lock.close()
  ignore(require_mirror_manager(pool, mirror_actor(pool, actor.id), repo))
  pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.query_opt(
          "SELECT c.host_keys FROM mirror_host_check c JOIN repository_mirror m ON m.id=c.mirror_id WHERE m.id=? AND m.repository_id=? AND m.version=? AND m.active=0 AND c.version=m.version AND c.url=m.url AND c.challenge=? AND c.created_at>=datetime('now','-10 minutes')",
          params=[id, scope.id, version, challenge],
        )
        is Some(row) else {
        raise @domain.BadRequest(
          message="Host confirmation expired or the mirror changed; reload and initialize the destination again",
        )
      }
      let keys : String = row.get_name("host_keys")
      ignore(
        tx.execute(
          "UPDATE repository_mirror SET host_keys=?,creator_id=?,version=version+1,generation=generation+1,status='disabled',attempts=0,last_error='',lease=NULL,locked_at=NULL WHERE id=?",
          params=[keys, actor.id, id],
        ),
      )
      ignore(
        tx.execute("DELETE FROM mirror_host_check WHERE mirror_id=?", params=[
          id,
        ]),
      )
      ignore(
        tx.execute(
          "INSERT INTO repository_audit(repository_id,actor_id,kind,detail) VALUES(?,?,'push_mirror_host_confirmed',?)",
          params=[scope.id, actor.id, id.to_string()],
        ),
      )
    })
  })
}
