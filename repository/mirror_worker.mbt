///|
priv struct MirrorJob {
  id : Int64
  scope : RepositoryScope
  actor : @domain.CurrentUser
  url : String
  host_keys : String
  force_push : Bool
  prune : Bool
  generation : Int64
  lease : String
  attempt_id : Int64
}

///|
fn mirror_actor(
  pool : @database.Database,
  creator_id : Int64,
) -> @domain.CurrentUser raise {
  pool.with_client(client => {
    guard client.query_opt(
        "SELECT * FROM \"user\" WHERE id=? AND status='active'",
        params=[creator_id],
      )
      is Some(row) else {
      raise @domain.Forbidden(message="mirror owner is no longer active")
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
fn claim_mirror(pool : @database.Database, id : Int64) -> MirrorJob? raise {
  pool.with_client(client => {
    client.with_transaction(tx => {
      // The per-mirror filesystem lock is already held: an old worker has stopped.
      ignore(
        tx.execute(
          "UPDATE mirror_attempt SET status='failed',error='Worker lease expired',completed_at=datetime('now') WHERE mirror_id=? AND status='syncing' AND EXISTS(SELECT 1 FROM repository_mirror WHERE id=? AND status='syncing' AND locked_at<=datetime('now','-2 hours'))",
          params=[id, id],
        ),
      )
      ignore(
        tx.execute(
          "UPDATE repository_mirror SET status=CASE WHEN attempts>=5 THEN 'failed' ELSE 'pending' END,lease=NULL,locked_at=NULL,last_error='Worker lease expired' WHERE id=? AND status='syncing' AND locked_at<=datetime('now','-2 hours')",
          params=[id],
        ),
      )
      guard tx.query_opt(
          "SELECT m.*,r.name,r.team_id,t.name_key AS owner FROM repository_mirror m JOIN repository r ON r.id=m.repository_id JOIN team t ON t.id=r.team_id WHERE m.id=? AND m.active=1 AND r.ready=1 AND m.status='pending' AND m.next_attempt_at<=datetime('now')",
          params=[id],
        )
        is Some(row) else {
        return None
      }
      let repo : @domain.RepoId = {
        owner: row.get_name("owner"),
        name: row.get_name("name"),
      }
      let actor = mirror_actor(pool, row.get_name("creator_id"))
      let scope = require_mirror_manager(pool, actor, repo)
      let generation : Int64 = row.get_name("generation")
      let lease = @identity.random_hex(16)
      ignore(
        tx.execute(
          "UPDATE repository_mirror SET status='syncing',attempts=attempts+1,lease=?,locked_at=datetime('now') WHERE id=?",
          params=[lease, id],
        ),
      )
      let attempt_id : Int64 = tx
        .query_one(
          "INSERT INTO mirror_attempt(mirror_id,generation,status) VALUES(?,?,'syncing') RETURNING id",
          params=[id, generation],
        )
        .get_name("id")
      Some({
        id,
        scope,
        actor,
        url: row.get_name("url"),
        host_keys: row.get_name("host_keys"),
        force_push: row.get_name("force_push"),
        prune: row.get_name("prune"),
        generation,
        lease,
        attempt_id,
      })
    })
  })
}

///|
async fn transfer_mirror(
  pool : @database.Database,
  root : String,
  job : MirrorJob,
  config : MirrorConfig,
) -> Unit {
  let target = parse_ssh_import_source(job.url)
  ignore(mirror_known_hosts(target, job.host_keys))
  let work = mirror_work_root(root)
  let stage = "\{work}/\{job.id}/\{job.lease}.git"
  @fs.mkdir(stage, permission=0o700)
  defer @fs.rmdir(stage, recursive=true)
  let environment = {
    "PATH": "/usr/bin:/bin",
    "LANG": "C.UTF-8",
    "HOME": stage,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_TERMINAL_PROMPT": "0",
  }
  run_repository_command(
    ["-c", "core.hooksPath=/dev/null", "init", "--bare", stage],
    environment,
  )
  {
    let dir = resolve_repository_dir(root, job.scope.repo)
    let lock = @gitops.repository_write_lock(dir)
    defer lock.close()
    ignore(require_mirror_manager(pool, job.actor, job.scope.repo))
    recover_ref_events_locked(pool, job.scope, dir)
    // Copy objects rather than sharing them: source GC cannot invalidate an in-flight snapshot.
    run_repository_command(
      [
        "--git-dir=\{stage}",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "protocol.allow=never",
        "-c",
        "protocol.file.allow=always",
        "fetch",
        "--no-tags",
        "--",
        dir,
        "+refs/heads/*:refs/heads/*",
        "+refs/tags/*:refs/tags/*",
      ],
      environment,
    )
  }
  // Recheck the current account and namespace permission immediately before external I/O.
  ignore(
    require_mirror_manager(
      pool,
      mirror_actor(pool, job.actor.id),
      job.scope.repo,
    ),
  )
  let known_hosts = mirror_known_hosts(target, job.host_keys)
  environment["GIT_SSH_COMMAND"] = config.ssh_command
  environment["GIT_SSH_VARIANT"] = "ssh"
  let key : String = pool.with_client(client => {
    guard client.query_opt(
        "SELECT private_key FROM mirror_ssh_key WHERE mirror_id=?",
        params=[job.id],
      )
      is Some(row) else {
      raise @domain.BadRequest(
        message="Save mirror settings to generate a dedicated SSH key",
      )
    }
    row.get_name("private_key")
  })
  let identity = stage + "/mirror_identity"
  @fs.write_file(identity, key, create_mode=@fs.CreateNew, permission=0o600)
  defer @fs.remove(identity)
  let hosts_file = stage + "/known_hosts"
  @fs.write_file(
    hosts_file,
    known_hosts,
    create_mode=@fs.CreateNew,
    permission=0o600,
  )
  environment["MOONHUB_MIRROR_IDENTITY"] = identity
  environment["MOONHUB_MIRROR_KNOWN_HOSTS"] = hosts_file
  let args = [
    "--git-dir=\{stage}",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "protocol.allow=never",
    "-c",
    "protocol.ssh.allow=always",
    "push",
    "--porcelain",
  ]
  if job.prune {
    args.push("--prune")
  }
  args.push("--")
  args.push(target.url)
  let prefix = if job.force_push { "+" } else { "" }
  args.push(prefix + "refs/heads/*:refs/heads/*")
  args.push(prefix + "refs/tags/*:refs/tags/*")
  run_repository_command(args, environment)
}

///|
pub async fn sync_next_mirror(
  pool : @database.Database,
  root : String,
  config : MirrorConfig,
) -> Bool {
  let id : Int64? = pool.with_client(client => {
    client
    .query_opt(
      "SELECT id FROM repository_mirror WHERE active=1 AND ((status='pending' AND next_attempt_at<=datetime('now')) OR (status='syncing' AND locked_at<=datetime('now','-2 hours'))) ORDER BY next_attempt_at,id LIMIT 1",
    )
    .map(row => row.get_name("id"))
  })
  guard id is Some(id) else { return false }
  let lock = mirror_lock(root, id)
  defer lock.close()
  let claimed = claim_mirror(pool, id) catch {
    @domain.Forbidden(_) | @domain.NotFound(_) => {
      pool.with_client(client => {
        ignore(
          client.execute(
            "UPDATE repository_mirror SET status='failed',last_error='Mirror owner no longer has repository management access' WHERE id=?",
            params=[id],
          ),
        )
      })
      None
    }
    err => raise err
  }
  guard claimed is Some(job) else { return true }
  let error = try {
    @async.with_timeout(config.timeout_ms, () => {
      transfer_mirror(pool, root, job, config)
    })
    ""
  } catch {
    @domain.BadRequest(_) =>
      "Sync failed. Check that this mirror’s public key has write access, and verify the destination’s host fingerprint and branch protection; then retry."
    _ =>
      "Sync failed. Check that this mirror’s public key has write access, and verify the destination’s host fingerprint and branch protection; then retry."
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      ignore(
        tx.execute(
          "UPDATE mirror_attempt SET status=?,error=?,completed_at=datetime('now') WHERE id=? AND status='syncing'",
          params=[
            if error.is_empty() {
              "succeeded"
            } else {
              "failed"
            },
            error,
            job.attempt_id,
          ],
        ),
      )
      ignore(
        tx.execute(
          "UPDATE repository_mirror SET status=CASE WHEN generation<>? THEN 'pending' WHEN ? THEN 'succeeded' WHEN attempts>=5 THEN 'failed' ELSE 'pending' END,synced_generation=CASE WHEN ? THEN ? ELSE synced_generation END,last_success_at=CASE WHEN ? THEN datetime('now') ELSE last_success_at END,last_error=?,next_attempt_at=CASE WHEN generation<>? THEN datetime('now') ELSE datetime('now','+' || CASE attempts WHEN 1 THEN 10 WHEN 2 THEN 60 WHEN 3 THEN 300 ELSE 1800 END || ' seconds') END,lease=NULL,locked_at=NULL WHERE id=? AND lease=?",
          params=[
            job.generation,
            error.is_empty(),
            error.is_empty(),
            job.generation,
            error.is_empty(),
            error,
            job.generation,
            id,
            job.lease,
          ],
        ),
      )
      ignore(
        tx.execute(
          "DELETE FROM mirror_attempt WHERE mirror_id=? AND id NOT IN (SELECT id FROM mirror_attempt WHERE mirror_id=? ORDER BY id DESC LIMIT 50)",
          params=[id, id],
        ),
      )
    })
  })
  true
}

///|
async fn recover_mirror_repositories(
  pool : @database.Database,
  root : String,
  after : Int64,
) -> Int64 {
  let rows = pool.with_client(client => {
    client.query_all(
      "SELECT DISTINCT r.id,r.name,r.team_id,t.name_key AS owner FROM mirror_ref_intent e JOIN repository r ON r.id=e.repository_id JOIN team t ON t.id=r.team_id WHERE e.state='prepared' AND r.id>? ORDER BY r.id LIMIT 20",
      params=[after],
    )
  })
  let mut cursor = 0L
  for row in rows {
    let scope : RepositoryScope = {
      id: row.get_name("id"),
      team_id: row.get_name("team_id"),
      repo: { owner: row.get_name("owner"), name: row.get_name("name"), },
    }
    cursor = scope.id
    try {
      let dir = resolve_repository_dir(root, scope.repo)
      let lock = @gitops.repository_write_lock(dir)
      defer lock.close()
      recover_mirror_refs_locked(pool, scope, dir)
    } catch {
      _ =>
        println(
          "mirror ref recovery requires inspection for repository \{scope.id}",
        )
    }
  }
  cursor
}

///|
pub fn start_mirror_worker(
  pool : @database.Database,
  root : String,
  config : MirrorConfig,
  group : @async.TaskGroup[Unit],
) -> Unit {
  group.spawn_bg(no_wait=true, allow_failure=true, () => {
    let mut cursor = 0L
    for ;; {
      let processed = try {
        cursor = recover_mirror_repositories(pool, root, cursor)
        sync_next_mirror(pool, root, config)
      } catch {
        _ => {
          println("mirror worker could not process a sync; retrying")
          false
        }
      }
      if !processed {
        @async.sleep(1000)
      }
    }
  })
}
