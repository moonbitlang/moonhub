///|
let managed_transfer_namespaces : String =
  #|SELECT t.id,t.name_key FROM team t
  #|JOIN "user" u ON u.id=? AND u.status='active'
  #|LEFT JOIN team_member m ON m.team_id=t.id AND m.user_id=u.id
  #|WHERE (u.is_site_admin=1 OR m.role IN ('owner','admin'))

///|
pub fn repository_transfer_targets(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  source_team_id : Int64,
) -> Array[(Int64, String)] raise {
  pool.with_client(client => {
    client
    .query_all(
      "\{managed_transfer_namespaces} AND t.id<>? ORDER BY t.name_key",
      params=[actor.id, source_team_id],
    )
    .map(row => (row.get_name("id"), row.get_name("name_key")))
  })
}

///|
fn require_transfer_namespace(
  client : @database.DbClient,
  actor_id : Int64,
  team_id : Int64,
) -> String raise {
  guard client.query_opt("\{managed_transfer_namespaces} AND t.id=?", params=[
      actor_id, team_id,
    ])
    is Some(row) else {
    raise @domain.Forbidden(
      message="namespace owner or admin access is required on both sides of the transfer",
    )
  }
  row.get_name("name_key")
}

///|
fn require_transfer_idle(client : @database.DbClient, id : Int64) -> Unit raise {
  require_repository_idle(client, id)
  guard client.query_opt(
      "SELECT j.merge_request_id FROM merge_job j JOIN merge_request m ON m.id=j.merge_request_id WHERE m.repository_id=? AND j.status IN ('pending','running') LIMIT 1",
      params=[id],
    )
    is None else {
    raise @domain.BadRequest(
      message="A merge is queued or running. Wait for it to finish, then retry.",
    )
  }
}

///|
fn transfer_lock_order(
  source : @domain.RepoId,
  target : @domain.RepoId,
) -> (@domain.RepoId, @domain.RepoId) {
  if source.owner < target.owner {
    (source, target)
  } else {
    (target, source)
  }
}

///|
async fn transfer_path_present(path : String) -> Bool {
  try @fs.kind(path, follow_symlink=false) catch {
    @os_error.OSError(_) as err if err.is_ENOENT() => false
    err => raise err
  } noraise {
    _ => true
  }
}

///|
async fn sync_transfer_directory(path : String) -> Unit {
  let directory = @fs.open(path, mode=ReadOnly)
  defer directory.close()
  directory.sync()
}

///|
async fn move_repository_directory(
  root : String,
  from : @domain.RepoId,
  to : @domain.RepoId,
) -> Unit {
  let path = resolve_repository_dir(root, from)
  let parent = "\{root}/\{to.owner}"
  guard @fs.kind(parent, follow_symlink=false) is Directory &&
    @fs.realpath(parent) == parent else {
    raise @domain.BadRequest(message="invalid repository owner directory")
  }
  // Do not commit SQLite ownership until the rename is durable on disk.
  @fs.rename(path, to.git_dir(root), replace=false)
  sync_transfer_directory(parent)
  sync_transfer_directory("\{root}/\{from.owner}")
}

///|
// The journal and ready flag are committed together. The original team_id
// remains authoritative until the durable move and final transaction succeed.
pub async fn transfer_repository(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
  target_team_id : Int64,
  confirmation : String,
) -> @domain.RepoId {
  let settings = repository_settings(pool, actor, repo)
  check_settings_identity(settings, id)
  let scope = settings.scope
  guard confirmation == repo.path() else {
    raise @domain.BadRequest(
      message="Enter the full repository name exactly: \{repo.path()}",
    )
  }
  guard target_team_id != scope.team_id else {
    raise @domain.BadRequest(message="Choose a different namespace")
  }
  let owner = pool.with_client(client => {
    require_transfer_namespace(client, actor.id, target_team_id)
  })
  let target = @domain.parse_transport_repo("\{owner}/\{repo.name}.git")
  let root = @domain.trim_trailing_slash(@fs.realpath(root))
  let (first, second) = transfer_lock_order(repo, target)
  let first_lock = repository_write_lock(root, first)
  defer first_lock.close()
  let second_lock = repository_write_lock(root, second)
  defer second_lock.close()
  guard @gitops.try_file_lock(repository_reader_lock_path(root, id))
    is Some(readers) else {
    raise @domain.BadRequest(
      message="A Git read is in progress. Wait for it to finish, then retry.",
    )
  }
  defer readers.close()
  require_current_scope(pool, scope)
  ignore(repository_settings(pool, actor, repo))
  let git_dir = resolve_repository_dir(root, repo)
  recover_ref_events_locked(pool, scope, git_dir)
  let parent = "\{root}/\{target.owner}"
  @fs.mkdir(parent, permission=0o750, allow_exist=true)
  guard @fs.kind(parent, follow_symlink=false) is Directory &&
    @fs.realpath(parent) == parent else {
    raise @domain.BadRequest(message="invalid destination namespace directory")
  }
  guard !transfer_path_present(target.git_dir(root)) else {
    raise @domain.BadRequest(
      message="Destination repository directory already exists",
    )
  }
  sync_transfer_directory(root)
  @async.protect_from_cancel(() => {
    pool.with_client(client => {
      client.with_transaction(
        tx => {
          require_current_scope(pool, scope)
          ignore(repository_settings(pool, actor, repo))
          guard require_transfer_namespace(client, actor.id, target_team_id) ==
            target.owner else {
            raise @domain.BadRequest(
              message="Destination namespace has changed",
            )
          }
          require_repository_name_available(client, target)
          guard tx.query_opt(
              "SELECT id FROM repository WHERE team_id=? AND name=?",
              params=[target_team_id, target.name],
            )
            is None else {
            raise @domain.BadRequest(
              message="Destination repository name is already taken",
            )
          }
          require_transfer_idle(client, id)
          ignore(
            tx.execute(
              "INSERT INTO repository_transfer(repository_id,target_team_id,name) VALUES(?,?,?)",
              params=[id, target_team_id, repo.name],
            ),
          )
          ignore(
            tx.execute("UPDATE repository SET ready=0 WHERE id=?", params=[id]),
          )
        },
        immediate=true,
      )
    })
    errdefer (@async.protect_from_cancel(() => {
      rollback_repository_transfer(pool, root, scope, target, target_team_id)
    }) catch {
      err => println("repository transfer recovery for \{id} failed: \{err}")
    })
    move_repository_directory(root, repo, target)
    pool.with_client(client => {
      client.with_transaction(
        tx => {
          guard require_transfer_namespace(client, actor.id, scope.team_id) ==
            repo.owner &&
            require_transfer_namespace(client, actor.id, target_team_id) ==
            target.owner else {
            raise @domain.BadRequest(
              message="A namespace has changed during transfer",
            )
          }
          require_transfer_idle(client, id)
          let changed = tx.execute(
            "UPDATE repository SET team_id=?,ready=1,updated_at=datetime('now') WHERE id=? AND team_id=? AND name=? AND ready=0",
            params=[target_team_id, id, scope.team_id, repo.name],
          )
          guard changed == 1 else {
            raise @domain.BadRequest(
              message="Repository has changed during transfer",
            )
          }
          retarget_attachment_links(tx, id, repo, target)
          ignore(
            tx.execute(
              "INSERT INTO repository_audit(repository_id,actor_id,kind,detail) VALUES(?,?,'repository_transferred',?)",
              params=[id, actor.id, "\{repo.path()} -> \{target.path()}"],
            ),
          )
          ignore(
            tx.execute(
              "DELETE FROM repository_transfer WHERE repository_id=?",
              params=[id],
            ),
          )
        },
        immediate=true,
      )
    })
    target
  })
}

///|
async fn rollback_repository_transfer(
  pool : @database.Database,
  root : String,
  scope : RepositoryScope,
  target : @domain.RepoId,
  target_team_id : Int64,
) -> Unit {
  // Recheck after taking both names' locks: another process could have completed
  // the transfer or recovery since this worker selected the journal row.
  guard pool.with_client(client => {
    client.query_opt(
      "SELECT r.id FROM repository_transfer x JOIN repository r ON r.id=x.repository_id JOIN team s ON s.id=r.team_id JOIN team t ON t.id=x.target_team_id WHERE r.id=? AND r.team_id=? AND r.name=x.name AND r.name=? AND r.ready=0 AND x.target_team_id=? AND s.name_key=? AND t.name_key=?",
      params=[
        scope.id,
        scope.team_id,
        scope.repo.name,
        target_team_id,
        scope.repo.owner,
        target.owner,
      ],
    )
    is Some(_)
  }) else {
    return
  }
  let source_exists = transfer_path_present(scope.repo.git_dir(root))
  let target_exists = transfer_path_present(target.git_dir(root))
  guard source_exists != target_exists else {
    raise @domain.BadRequest(
      message="ambiguous repository transfer paths; operator inspection required",
    )
  }
  if target_exists {
    move_repository_directory(root, target, scope.repo)
  } else {
    ignore(resolve_repository_dir(root, scope.repo))
    // A prior rollback may have renamed the directory but failed to sync it.
    sync_transfer_directory("\{root}/\{scope.repo.owner}")
    sync_transfer_directory("\{root}/\{target.owner}")
  }
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        ignore(
          tx.execute("UPDATE repository SET ready=1 WHERE id=?", params=[
            scope.id,
          ]),
        )
        ignore(
          tx.execute("DELETE FROM repository_transfer WHERE repository_id=?", params=[
            scope.id,
          ]),
        )
      },
      immediate=true,
    )
  })
}

///|
async fn recover_repository_transfers(
  pool : @database.Database,
  root : String,
  after~ : Int64 = 0L,
) -> Int64 {
  let rows = pool.with_client(client => {
    client.query_all(
      "SELECT r.id,r.team_id,x.target_team_id,x.name,s.name_key AS source,t.name_key AS target FROM repository_transfer x JOIN repository r ON r.id=x.repository_id JOIN team s ON s.id=r.team_id JOIN team t ON t.id=x.target_team_id WHERE r.id>? ORDER BY r.id LIMIT 20",
      params=[after],
    )
  })
  let mut cursor = 0L
  for row in rows {
    let id : Int64 = row.get_name("id")
    cursor = id
    try {
      let name : String = row.get_name("name")
      let source : String = row.get_name("source")
      let target : String = row.get_name("target")
      guard source != target else {
        raise @domain.BadRequest(message="invalid repository transfer journal")
      }
      let repo = @domain.parse_transport_repo("\{source}/\{name}.git")
      let target = @domain.parse_transport_repo("\{target}/\{name}.git")
      let scope : RepositoryScope = {
        id,
        team_id: row.get_name("team_id"),
        repo,
      }
      let (first, second) = transfer_lock_order(repo, target)
      guard @gitops.try_file_lock(repository_lock_path(root, first))
        is Some(first_lock) else {
        continue
      }
      defer first_lock.close()
      guard @gitops.try_file_lock(repository_lock_path(root, second))
        is Some(second_lock) else {
        continue
      }
      defer second_lock.close()
      guard @gitops.try_file_lock(repository_reader_lock_path(root, id))
        is Some(readers) else {
        continue
      }
      defer readers.close()
      let root = @domain.trim_trailing_slash(@fs.realpath(root))
      @async.protect_from_cancel(() => {
        rollback_repository_transfer(
          pool,
          root,
          scope,
          target,
          row.get_name("target_team_id"),
        )
      })
    } catch {
      err if @async.is_being_cancelled() => raise err
      err => println("repository transfer recovery for \{id} failed: \{err}")
    }
  }
  cursor
}
