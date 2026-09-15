///|
struct SshPublicKey {
  public_key : String
  fingerprint : String
}

///|
struct SshRequest {
  repo : RepoId
  operation : RepoOperation
}

///|
fn parse_ssh_public_key(text : String) -> SshPublicKey raise {
  let text = text.trim().to_owned()
  guard text.length() <= 16384 && !text.contains("\n") && !text.contains("\r") else {
    raise BadRequest(message="expected one OpenSSH Ed25519 public key")
  }
  let fields = text
    .replace(old="\t", new=" ")
    .split(" ")
    .filter(field => !field.is_empty())
    .collect()
  guard fields.length() >= 2 && fields[0] == "ssh-ed25519" else {
    raise BadRequest(message="only OpenSSH Ed25519 public keys are supported")
  }
  let bytes = @base64.decode(fields[1]) catch {
    _ => raise BadRequest(message="invalid public key encoding")
  }
  let prefix = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
  guard bytes.length() == 51 else {
    raise BadRequest(message="invalid Ed25519 public key")
  }
  for i = 0; i < prefix.length(); i = i + 1 {
    guard bytes[i] == prefix[i] else {
      raise BadRequest(message="invalid Ed25519 public key")
    }
  }
  {
    public_key: "ssh-ed25519 \{@base64.encode(bytes)}",
    fingerprint: "SHA256:\{@base64.encode(Bytes::from_array(@crypto.sha256(bytes)), padding=false)}",
  }
}

///|
fn parse_transport_repo(path : String) -> RepoId raise {
  let path = path.strip_prefix("/").unwrap_or(path[:])
  let parts = path.split("/").collect()
  guard parts.length() == 2 else {
    raise BadRequest(message="expected owner/repository.git")
  }
  let owner = parts[0].to_owned()
  let name = parts[1].strip_suffix(".git").unwrap_or(parts[1]).to_owned()
  guard valid_name_key(owner) && !name.is_empty() && name.length() <= 100 else {
    raise BadRequest(message="invalid repository name")
  }
  for i, ch in name {
    let alphanumeric = ch.is_ascii_alphabetic() || ch.is_ascii_digit()
    guard alphanumeric || (i > 0 && (ch == '-' || ch == '_' || ch == '.')) else {
      raise BadRequest(message="invalid repository name")
    }
  }
  { owner, name, }
}

///|
fn parse_ssh_request(command : String) -> SshRequest raise {
  guard command.length() <= 1024 else {
    raise BadRequest(message="SSH command too long")
  }
  guard command.split_once(" ") is Some((service, argument)) else {
    raise BadRequest(message="only Git fetch and push commands are allowed")
  }
  let operation = match service {
    "git-upload-pack" => Read
    "git-receive-pack" => Write
    _ =>
      raise BadRequest(message="only Git fetch and push commands are allowed")
  }
  let argument = argument.trim()
  guard argument.has_prefix("'") &&
    argument.has_suffix("'") &&
    argument.length() > 2 else {
    raise BadRequest(message="expected a single quoted repository path")
  }
  let repo = parse_transport_repo(argument[1:argument.length() - 1].to_owned())
  { repo, operation, }
}

///|
fn add_ssh_key(
  pool : Database,
  user : CurrentUser,
  title : String,
  key : SshPublicKey,
) -> Int64 raise {
  guard !title.trim().is_empty() && title.length() <= 200 else {
    raise BadRequest(message="key title must contain 1 to 200 characters")
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.query_opt("SELECT id FROM ssh_key WHERE fingerprint = ?", params=[
          key.fingerprint,
        ])
        is None else {
        raise BadRequest(
          message="this public key is already registered (possibly revoked)",
        )
      }
      let row = tx.query_one(
        (
          #|INSERT INTO ssh_key (user_id, title, public_key, fingerprint)
          #|VALUES (?, ?, ?, ?) RETURNING id
        ),
        params=[user.id, title, key.public_key, key.fingerprint],
      )
      row.get_name("id")
    })
  })
}

///|
fn ssh_key_user(pool : Database, key_id : Int64) -> CurrentUser raise {
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
      raise Unauthorized(message="SSH key is not authorized")
    }
    {
      id: row.get_name("id"),
      name_key: row.get_name("name_key"),
      display_name: row.get_name("display_name"),
      is_site_admin: row.get_name("is_site_admin"),
    }
  })
}

///|
fn authorized_ssh_key(pool : Database, key : SshPublicKey) -> String? raise {
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
    guard row is Some(row) else { return None }
    let id : Int64 = row.get_name("id")
    let public_key : String = row.get_name("public_key")
    Some(
      "restrict,command=\"/usr/local/bin/moonhub ssh-serve \{id}\" \{public_key}",
    )
  })
}

///|
async fn serve_git_ssh(pool : Database, key_id : Int64, root : String) -> Int {
  let user = ssh_key_user(pool, key_id)
  let command = @env.get_env_var("SSH_ORIGINAL_COMMAND").unwrap_or("")
  if command.is_empty() {
    @stdio.stderr.write(
      "Authenticated as \{user.name_key}. Shell access is disabled.\n",
    )
    return 0
  }
  let request = parse_ssh_request(command)
  authorize_repository(pool, user, request.repo, request.operation)
  let git_dir = resolve_repository_dir(root, request.repo)
  let write_lock = if request.operation == Write {
    Some(@gitops.repository_write_lock(git_dir))
  } else {
    None
  }
  defer (if write_lock is Some(lock) { lock.close() })
  let git_command = match request.operation {
    Read => "upload-pack"
    Write => "receive-pack"
  }
  let environment = { "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8" }
  let protected_args = ["-c", "transfer.hideRefs=refs/moonhub/"]
  if request.operation == Write {
    // The directory is deployment-owned, never a hook supplied by a repository.
    let hooks = @env.get_env_var("MOONHUB_HOOKS_PATH").unwrap_or(
      "/usr/local/lib/moonhub/hooks",
    )
    guard @fs.kind("\{hooks}/pre-receive", follow_symlink=false) is Regular else {
      raise BadRequest(message="Moonhub receive hook is not installed")
    }
    protected_args.push("-c")
    protected_args.push("core.hooksPath=\{hooks}")
    environment["MOONHUB_KEY_ID"] = key_id.to_string()
    environment["MOONHUB_REPOSITORY"] = request.repo.path()
    environment["DB_PATH"] = @env.get_env_var("DB_PATH").unwrap_or("moonhub.db")
    environment["MOONHUB_BIN"] = @env.get_env_var("MOONHUB_BIN").unwrap_or(
      "/usr/local/bin/moonhub",
    )
  }
  match @env.get_env_var("GIT_PROTOCOL") {
    Some("version=0" | "version=1" | "version=2" as version) =>
      environment["GIT_PROTOCOL"] = version
    _ => ()
  }
  pool.with_client(client => {
    let _ = client.execute(
      "UPDATE ssh_key SET last_used_at = datetime('now') WHERE id = ?",
      params=[key_id],
    )
  })
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM, SIGHUP])
  @process.run(
    @env.get_env_var("MOONHUB_GIT").unwrap_or("git"),
    [
      "-c", "receive.fsckObjects=true", "-c", "receive.maxInputSize=1073741824",
      ..protected_args, git_command, git_dir,
    ],
    inherit_env=false,
    extra_env=environment,
    stdin=@stdio.stdin,
    stdout=@stdio.stdout,
    stderr=@stdio.stderr,
  )
}
