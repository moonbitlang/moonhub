///|
async fn repository_work_directory(root : String) -> String {
  let root = @domain.trim_trailing_slash(@fs.realpath(root))
  let directory = "\{root}/.imports"
  if !@fs.exists(directory) {
    @fs.mkdir(directory, permission=0o700) catch {
      err => if !@fs.exists(directory) { raise err }
    }
  }
  guard @fs.realpath(directory) == directory &&
    @fs.kind(directory, follow_symlink=false) is Directory else {
    raise @domain.BadRequest(message="invalid repository staging directory")
  }
  directory
}

///|
async fn clean_repository_stage(
  work : String,
  id : Int64,
  token : String,
) -> Unit {
  if token.is_empty() {
    return
  }
  guard token.length() == 32 else {
    raise @domain.BadRequest(message="invalid repository staging token")
  }
  for ch in token {
    guard ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f') else {
      raise @domain.BadRequest(message="invalid repository staging token")
    }
  }
  let stage = "\{work}/\{id}-\{token}.git"
  if @fs.exists(stage) {
    guard @fs.realpath(stage) == stage else {
      raise @domain.BadRequest(message="invalid repository staging path")
    }
    @fs.rmdir(stage, recursive=true)
  }
}

///|
async fn run_repository_command(
  args : Array[String],
  environment : Map[String, String],
) -> Unit {
  @async.with_task_group(group => {
    let (reader, writer) = @process.read_from_process()
    defer reader.close()
    let process = @process.spawn(
      group,
      "git",
      args,
      inherit_env=false,
      extra_env=environment,
      stdin=@process.redirect_from_file("/dev/null"),
      stdout=writer,
      stderr=writer,
    )
    let diagnostic : Array[Byte] = []
    while reader.read_some(max_len=4096) is Some(chunk) {
      for byte in chunk {
        if diagnostic.length() < 8192 {
          diagnostic.push(byte)
        }
      }
    }
    let code = process.wait()
    // Git can exit with an ordinary failure code while cancellation terminates
    // its SSH child. Do not let that failure replace the enclosing timeout.
    @async.pause()
    guard code == 0 else {
      raise @domain.BadRequest(
        message="Git exited with status \{code}: \{@utf8.decode_lossy(Bytes::from_array(diagnostic))}",
      )
    }
  })
}

///|
fn repository_job_actor(
  pool : @database.Database,
  job : RepositoryJob,
) -> @domain.CurrentUser raise {
  pool.with_client(client => {
    let row = client.query_opt(
      "SELECT id, name_key, display_name, is_site_admin FROM \"user\" WHERE id = ? AND status = 'active'",
      params=[job.requester_id],
    )
    guard row is Some(row) else {
      raise @domain.Forbidden(message="the requesting user is no longer active")
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
async fn provision_repository(
  pool : @database.Database,
  root : String,
  config : RepoImportConfig?,
  job : RepositoryJob,
  stage : String,
  addresses : SshAddressConfig,
) -> Unit {
  let actor = repository_job_actor(pool, job)
  guard @identity.get_team_by_name_key(pool, job.repo.owner) is Some(team) else {
    raise @domain.NotFound(message="team not found")
  }
  guard team.id == job.team_id else {
    raise @domain.NotFound(message="repository team no longer matches")
  }
  require_repository_manager(pool, actor, team)
  let job = pin_legacy_repository_source(pool, actor, job, addresses)
  let source = repository_job_source(pool, actor, job, addresses)
  let checked = @domain.parse_transport_repo("\{job.repo.path()}.git")
  guard checked.path() == job.repo.path() else {
    raise @domain.BadRequest(message="invalid repository identity")
  }
  let root = @domain.trim_trailing_slash(@fs.realpath(root))
  let destination = job.repo.git_dir(root)
  let owner = "\{root}/\{job.repo.owner}"
  if !@fs.exists(owner) {
    @fs.mkdir(owner, permission=0o750)
  }
  guard @fs.realpath(owner) == owner else {
    raise @domain.BadRequest(
      message="repository owner directory must not be a symbolic link",
    )
  }
  if @fs.exists(destination) {
    // The marker is written only after Git completes. It makes the final rename
    // recoverable if the server exits before committing the database update.
    guard @fs.realpath(destination) == destination else {
      raise @domain.BadRequest(message="repository path already exists")
    }
    let marker = @fs.read_file("\{destination}/moonhub-provisioned").text() catch {
      _ => ""
    }
    guard marker == job.id.to_string() else {
      raise @domain.BadRequest(
        message="repository data already exists and will not be overwritten",
      )
    }
  } else {
    @fs.mkdir(stage, permission=0o700)
    let environment = {
      "PATH": "/usr/bin:/bin",
      "LANG": "C.UTF-8",
      "HOME": stage,
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_TERMINAL_PROMPT": "0",
    }
    if job.source_url.is_empty() {
      run_repository_command(
        [
          "-c", "core.hooksPath=/dev/null", "init", "--bare", "--initial-branch=main",
          stage,
        ],
        environment,
      )
    } else {
      guard config is Some(config) else {
        raise @domain.BadRequest(message="SSH imports are not configured")
      }
      let source = source.unwrap()
      let credentials = team_import_credentials(config, job.repo.owner)
      authorize_import_source(credentials, source)
      environment["GIT_SSH"] = config.ssh_wrapper
      environment["GIT_SSH_VARIANT"] = "ssh"
      environment["MOONHUB_IMPORT_IDENTITY"] = credentials.identity
      environment["MOONHUB_IMPORT_KNOWN_HOSTS"] = credentials.known_hosts
      run_repository_command(
        [
          "-c",
          "protocol.allow=never",
          "-c",
          "protocol.ssh.allow=always",
          "-c",
          "core.hooksPath=/dev/null",
          "-c",
          "fetch.fsckObjects=true",
          "clone",
          "--mirror",
          "--no-local",
          "--",
          source.url,
          stage,
        ],
        environment,
      )
      run_repository_command(
        ["--git-dir=\{stage}", "config", "--remove-section", "remote.origin"],
        environment,
      )
    }
    let actor = repository_job_actor(pool, job)
    require_repository_manager(pool, actor, team)
    ignore(repository_job_source(pool, actor, job, addresses))
    @fs.write_file(
      "\{stage}/moonhub-provisioned",
      job.id.to_string(),
      permission=0o600,
    )
    @fs.rename(stage, destination, replace=false)
  }
  let branch = @gitops.default_ref(destination)
  let actor = repository_job_actor(pool, job)
  require_repository_manager(pool, actor, team)
  ignore(repository_job_source(pool, actor, job, addresses))
  pool.with_client(client => {
    client.with_transaction(tx => {
      let _ = tx.execute(
        "UPDATE repository SET ready = 1, default_branch = ?, updated_at = datetime('now') WHERE id = ?",
        params=[branch, job.id],
      )
      let _ = tx.execute(
        "UPDATE repository_job SET status = 'succeeded', stage_token = '', last_error = NULL, updated_at = datetime('now') WHERE repository_id = ?",
        params=[job.id],
      )
    })
  })
}

///|
pub async fn run_next_repository_job(
  pool : @database.Database,
  root : String,
  config : RepoImportConfig?,
  addresses~ : SshAddressConfig = no_ssh_address_config,
) -> Bool {
  let exists = pool.with_client(client => {
    client.query_opt(
      "SELECT repository_id FROM repository_job WHERE status IN ('pending', 'running') LIMIT 1",
    )
  })
  guard exists is Some(_) else { return false }
  let work = repository_work_directory(root)
  let lock = @fs.open(
    "\{work}/worker.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  // A shared-volume lock serializes workers and releases automatically on exit,
  // so a remaining 'running' row belongs to an interrupted operation.
  guard lock.try_lock(Exclusive) else { return false }
  let row = pool.with_client(client => {
    client.query_opt(
      "\{repository_job_select} WHERE j.status IN ('pending', 'running') ORDER BY r.id LIMIT 1",
    )
  })
  guard row is Some(row) else { return false }
  let job = RepositoryJob::from_row(row)
  let token = @identity.random_hex(16)
  let stage = "\{work}/\{job.id}-\{token}.git"
  defer (@async.protect_from_cancel(() => {
    @async.with_timeout(10000, () => clean_repository_stage(work, job.id, token))
  }) catch {
    err => println("repository staging cleanup failed: \{err}")
  })
  try {
    clean_repository_stage(work, job.id, job.stage_token)
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository_job SET status = 'running', stage_token = ?, attempt_count = attempt_count + 1, updated_at = datetime('now'), last_error = NULL WHERE repository_id = ?",
        params=[token, job.id],
      )
    })
    let timeout = match config {
      Some(config) => config.timeout_ms
      None => 300000
    }
    @async.with_timeout(
      timeout,
      () => provision_repository(pool, root, config, job, stage, addresses),
      error=@domain.BadRequest(message="repository operation timed out"),
    )
  } catch {
    err if @async.is_being_cancelled() => {
      @async.pause()
      raise err
    }
    err => {
      println("repository job \{job.id} failed: \{err}")
      let message = match err {
        @domain.BadRequest(message~)
        | @domain.Forbidden(message~)
        | @domain.Unauthorized(message~)
        | @domain.NotFound(message~) => message
        @gitops.GitCommandFailed(code~, output~) =>
          "Git exited with status \{code}: \{output}"
        _ => "Repository operation failed: \{err}"
      }
      pool.with_client(client => {
        let _ = client.execute(
          "UPDATE repository_job SET status = 'failed', last_error = ?, updated_at = datetime('now') WHERE repository_id = ?",
          params=[message, job.id],
        )
      })
    }
  }
  true
}

///|
pub fn start_repository_worker(
  pool : @database.Database,
  root : String,
  config : RepoImportConfig?,
  group : @async.TaskGroup[Unit],
  addresses~ : SshAddressConfig = no_ssh_address_config,
) -> Unit {
  group.spawn_bg(no_wait=true, () => {
    for ;; {
      let processed = run_next_repository_job(pool, root, config, addresses~) catch {
        err => {
          println("repository worker error: \{err}")
          false
        }
      }
      if !processed {
        @async.sleep(1000)
      }
    }
  })
}
