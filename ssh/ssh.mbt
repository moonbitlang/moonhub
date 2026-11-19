///|
pub struct SshPublicKey {
  public_key : String
  fingerprint : String
}

///|
priv struct SshRequest {
  repo : @domain.RepoId
  operation : @repository.RepoOperation
}

///|
pub fn parse_ssh_public_key(text : String) -> SshPublicKey raise {
  let text = text.trim().to_owned()
  guard text.length() <= 16384 && !text.contains("\n") && !text.contains("\r") else {
    raise @domain.BadRequest(message="expected one OpenSSH Ed25519 public key")
  }
  let fields = text
    .replace(old="\t", new=" ")
    .split(" ")
    .filter(field => !field.is_empty())
    .collect()
  guard fields.length() >= 2 && fields[0] == "ssh-ed25519" else {
    raise @domain.BadRequest(
      message="only OpenSSH Ed25519 public keys are supported",
    )
  }
  let bytes = @base64.decode(fields[1]) catch {
    _ => raise @domain.BadRequest(message="invalid public key encoding")
  }
  let prefix = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
  guard bytes.length() == 51 else {
    raise @domain.BadRequest(message="invalid Ed25519 public key")
  }
  for i = 0; i < prefix.length(); i = i + 1 {
    guard bytes[i] == prefix[i] else {
      raise @domain.BadRequest(message="invalid Ed25519 public key")
    }
  }
  {
    public_key: "ssh-ed25519 \{@base64.encode(bytes)}",
    fingerprint: "SHA256:\{@base64.encode(Bytes::from_array(@crypto.sha256(bytes)), padding=false)}",
  }
}

///|
fn parse_ssh_request(command : String) -> SshRequest raise {
  guard command.length() <= 1024 else {
    raise @domain.BadRequest(message="SSH command too long")
  }
  guard command.split_once(" ") is Some((service, argument)) else {
    raise @domain.BadRequest(
      message="only Git fetch and push commands are allowed",
    )
  }
  let operation = match service {
    "git-upload-pack" => @repository.Read
    "git-receive-pack" => @repository.Write
    _ =>
      raise @domain.BadRequest(
        message="only Git fetch and push commands are allowed",
      )
  }
  let argument = argument.trim()
  guard argument.has_prefix("'") &&
    argument.has_suffix("'") &&
    argument.length() > 2 else {
    raise @domain.BadRequest(message="expected a single quoted repository path")
  }
  let repo = @domain.parse_transport_repo(
    argument[1:argument.length() - 1].to_owned(),
  )
  { repo, operation, }
}

///|
pub fn add_ssh_key(
  pool : @database.Database,
  user : @domain.CurrentUser,
  title : String,
  key : SshPublicKey,
) -> Int64 raise {
  guard !title.trim().is_empty() && title.length() <= 200 else {
    raise @domain.BadRequest(
      message="key title must contain 1 to 200 characters",
    )
  }
  let key = parse_ssh_public_key(key.public_key)
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        require_unused_public_key(tx, key)
        let row = tx.query_opt(
          (
            #|INSERT INTO ssh_key (user_id, title, public_key, fingerprint)
            #|VALUES (?, ?, ?, ?) ON CONFLICT (fingerprint) DO NOTHING RETURNING id
          ),
          params=[user.id, title, key.public_key, key.fingerprint],
        )
        guard row is Some(row) else {
          raise @domain.BadRequest(
            message="this public key is already registered (possibly revoked)",
          )
        }
        row.get_name("id")
      },
      immediate=true,
    )
  })
}

///|
fn ssh_key_user(
  pool : @database.Database,
  key_id : Int64,
) -> @domain.CurrentUser raise {
  pool.with_client(client => {
    let row = client.query_opt(
      (
        #|SELECT "user".id, "user".name_key, "user".display_name, "user".is_site_admin
        #|FROM ssh_key JOIN "user" ON "user".id = ssh_key.user_id
        #|WHERE ssh_key.id = ? AND ssh_key.revoked_at IS NULL AND "user".status = 'active'
      ),
      params=[key_id],
    )
    guard row is Some(row) else {
      raise @domain.Unauthorized(message="SSH key is not authorized")
    }
    {
      id: row.get_name("id"),
      name_key: row.get_name("name_key"),
      display_name: row.get_name("display_name"),
      is_site_admin: row.get_name("is_site_admin"),
      time_zone: None,
    }
  })
}

///|
pub fn authorized_ssh_key(
  pool : @database.Database,
  key : SshPublicKey,
) -> String? raise {
  pool.with_client(client => {
    let row = client.query_opt(
      (
        #|SELECT ssh_key.id, ssh_key.public_key
        #|FROM ssh_key JOIN "user" ON "user".id = ssh_key.user_id
        #|WHERE ssh_key.public_key = ? AND ssh_key.revoked_at IS NULL
        #|  AND "user".status = 'active'
      ),
      params=[key.public_key],
    )
    if row is Some(row) {
      let id : Int64 = row.get_name("id")
      let public_key : String = row.get_name("public_key")
      return Some(
        "restrict,command=\"/usr/local/bin/moonhub ssh-serve \{id}\" \{public_key}",
      )
    }
    let row = client.query_opt(
      (
        #|SELECT k.id, k.public_key FROM repository_deploy_key k
        #|JOIN repository r ON r.id = k.repository_id
        #|WHERE k.public_key = ? AND k.revoked_at IS NULL AND r.ready = 1
      ),
      params=[key.public_key],
    )
    guard row is Some(row) else { return None }
    let id : Int64 = row.get_name("id")
    let public_key : String = row.get_name("public_key")
    Some(
      "restrict,command=\"/usr/local/bin/moonhub ssh-serve deploy:\{id}\" \{public_key}",
    )
  })
}

///|
pub async fn serve_git_ssh(
  pool : @database.Database,
  credential : SshCredential,
  root : String,
  read_idle_timeout_seconds~ : Int32 = 120,
  read_max_seconds~ : Int32 = 3600,
) -> Int32 {
  guard read_idle_timeout_seconds >= 1 &&
    read_idle_timeout_seconds <= 2147483 &&
    read_max_seconds >= 1 &&
    read_max_seconds <= 2147483 else {
    raise @domain.BadRequest(
      message="SSH read timeouts must be between 1 and 2147483 seconds",
    )
  }
  let command = @env.get_env_var("SSH_ORIGINAL_COMMAND").unwrap_or("")
  if command.is_empty() {
    let name = match credential {
      UserKey(id) => ssh_key_user(pool, id).name_key
      DeployKey(id) => {
        let (scope, _) = deploy_key_binding(pool, id)
        "deploy key for \{scope.repo.path()}"
      }
    }
    @stdio.stderr.write("Authenticated as \{name}. Shell access is disabled.\n")
    return 0
  }
  let request = parse_ssh_request(command)
  let scope = authorize_git_operation(
    pool,
    credential,
    request.repo,
    request.operation,
  )
  let lock = if request.operation == @repository.Write {
    @repository.repository_write_lock(root, scope.repo)
  } else {
    @repository.repository_read_lock(root, scope.repo)
  }
  defer lock.close()
  ignore(
    authorize_git_operation(pool, credential, request.repo, request.operation),
  )
  @repository.require_current_scope(pool, scope)
  let reader = if request.operation == @repository.Read {
    Some(@repository.repository_reader_lock(root, scope.id))
  } else {
    None
  }
  defer (if reader is Some(reader) { reader.close() })
  let git_dir = @repository.resolve_repository_dir(root, scope.repo)
  if request.operation == @repository.Write {
    @repository.recover_ref_events_locked(pool, scope, git_dir)
  }
  let git_command = match request.operation {
    @repository.Read => "upload-pack"
    @repository.Write => "receive-pack"
  }
  let environment = { "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8" }
  let protected_args = ["-c", "transfer.hideRefs=refs/moonhub/"]
  if request.operation == @repository.Write {
    // The directory is deployment-owned, never a hook supplied by a repository.
    let hooks = @env.get_env_var("MOONHUB_HOOKS_PATH").unwrap_or(
      "/usr/local/lib/moonhub/hooks",
    )
    for name in ["pre-receive", "reference-transaction"] {
      guard @fs.kind("\{hooks}/\{name}", follow_symlink=false) is Regular &&
        @fs.can_execute("\{hooks}/\{name}") else {
        raise @domain.BadRequest(
          message="Moonhub receive hooks must be installed and executable",
        )
      }
    }
    protected_args.push("-c")
    protected_args.push("core.hooksPath=\{hooks}")
    environment["MOONHUB_KEY_ID"] = credential.argument()
    environment["MOONHUB_PUSH_ID"] = @identity.random_hex(16)
    environment["MOONHUB_REPOSITORY"] = request.repo.path()
    environment["DB_PATH"] = @env.get_env_var("DB_PATH").unwrap_or("moonhub.db")
    environment["MOONHUB_BIN"] = @env.get_env_var("MOONHUB_BIN").unwrap_or(
      "/usr/local/bin/moonhub",
    )
  }
  if @env.get_env_var("GIT_PROTOCOL")
    is Some("version=0" | "version=1" | "version=2" as version) {
    environment["GIT_PROTOCOL"] = version
  }
  // Filesystem checks and event recovery may yield; do not start a transfer
  // using authorization from before a revocation or access-mode change.
  ignore(
    authorize_git_operation(pool, credential, request.repo, request.operation),
  )
  @repository.require_current_scope(pool, scope)
  pool.with_client(client => {
    let (table, key_id) = match credential {
      UserKey(id) => ("ssh_key", id)
      DeployKey(id) => ("repository_deploy_key", id)
    }
    let _ = client.execute(
      "UPDATE \{table} SET last_used_at = datetime('now') WHERE id = ? AND revoked_at IS NULL",
      params=[key_id],
    )
  })
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM, SIGHUP])
  let git = @env.get_env_var("MOONHUB_GIT").unwrap_or("git")
  let args = [
    "-c", "receive.fsckObjects=true", "-c", "receive.maxInputSize=1073741824", ..protected_args,
    git_command,
  ]
  if request.operation == @repository.Read {
    args.push("--timeout=\{read_idle_timeout_seconds}")
    args.push(git_dir)
    // The deadline includes startup. The group reaps Git on every exit path
    // before the outer defer releases the original repository's reader lock.
    return @async.with_timeout(
      read_max_seconds * 1000,
      () => {
        @async.with_task_group(group => {
          group.spawn_bg(no_wait=true, () => {
            for ;; {
              @repository.require_current_scope(pool, scope)
              @async.sleep(1000)
            }
          })
          let process = @process.spawn(
            group,
            git,
            args,
            inherit_env=false,
            extra_env=environment,
            stdin=@stdio.stdin,
            stdout=@stdio.stdout,
            stderr=@stdio.stderr,
            cancel_handler=@process.graceful_cancel(timeout=5000),
          )
          lock.close()
          process.wait()
        })
      },
      error=@domain.BadRequest(message="SSH read exceeded its maximum duration"),
    )
  }
  args.push(git_dir)
  let code = @process.run(
    git,
    args,
    inherit_env=false,
    extra_env=environment,
    stdin=@stdio.stdin,
    stdout=@stdio.stdout,
    stderr=@stdio.stderr,
  )
  if request.operation == @repository.Write {
    @repository.recover_ref_events_locked(pool, scope, git_dir)
  }
  code
}
