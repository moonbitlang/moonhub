///|
pub(all) struct PushMirror {
  id : Int64
  url : String
  public_key : String
  active : Bool
  force_push : Bool
  prune : Bool
  version : Int64
  status : String
  attempts : Int64
  error : String
  last_success_at : String?
  next_attempt_at : String
}

///|
pub(all) struct MirrorAttempt {
  status : String
  error : String
  started_at : String
  completed_at : String?
}

///|
pub fn require_mirror_manager(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> RepositoryScope raise {
  let scope = repository_scope(pool, actor, repo)
  guard @identity.can_manage_team(pool, actor, scope.team_id) else {
    raise @domain.Forbidden(message="repository owner or admin required")
  }
  scope
}

///|
pub fn push_mirrors(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> Array[PushMirror] raise {
  let scope = require_mirror_manager(pool, actor, repo)
  pool.with_client(client => {
    client
    .query_all(
      "SELECT m.id,m.url,m.active,m.force_push,m.prune,m.version,m.status,m.attempts,m.last_error,m.last_success_at,m.next_attempt_at,COALESCE(k.public_key,'') AS public_key FROM repository_mirror m LEFT JOIN mirror_ssh_key k ON k.mirror_id=m.id WHERE m.repository_id=? ORDER BY m.id",
      params=[scope.id],
    )
    .map(row => {
      id: row.get_name("id"),
      url: row.get_name("url"),
      public_key: row.get_name("public_key"),
      active: row.get_name("active"),
      force_push: row.get_name("force_push"),
      prune: row.get_name("prune"),
      version: row.get_name("version"),
      status: row.get_name("status"),
      attempts: row.get_name("attempts"),
      error: row.get_name("last_error"),
      last_success_at: row.get_name("last_success_at"),
      next_attempt_at: row.get_name("next_attempt_at"),
    })
  })
}

///|
pub fn mirror_history(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
) -> Array[MirrorAttempt] raise {
  let scope = require_mirror_manager(pool, actor, repo)
  pool.with_client(client => {
    client
    .query_all(
      "SELECT a.* FROM mirror_attempt a JOIN repository_mirror m ON m.id=a.mirror_id WHERE m.repository_id=? AND m.id=? ORDER BY a.id DESC LIMIT 10",
      params=[scope.id, id],
    )
    .map(row => {
      status: row.get_name("status"),
      error: row.get_name("error"),
      started_at: row.get_name("started_at"),
      completed_at: row.get_name("completed_at"),
    })
  })
}

///|
async fn mirror_work_root(root : String) -> String {
  let root = @domain.trim_trailing_slash(@fs.realpath(root))
  let work = "\{root}/.mirrors"
  if !@fs.exists(work) {
    @fs.mkdir(work, permission=0o700) catch {
      err => if !@fs.exists(work) { raise err }
    }
  }
  guard @fs.realpath(work) == work &&
    @fs.kind(work, follow_symlink=false) is Directory else {
    raise @domain.BadRequest(message="invalid mirror working directory")
  }
  work
}

///|
async fn mirror_lock(root : String, id : Int64) -> @fs.File {
  let work = mirror_work_root(root)
  // This lock is independent of the source repository's receive/merge lock.
  let directory = work + "/" + id.to_string()
  if !@fs.exists(directory) {
    @fs.mkdir(directory, permission=0o700) catch {
      err => if !@fs.exists(directory) { raise err }
    }
  }
  guard @fs.realpath(directory) == directory else {
    raise @domain.BadRequest(message="invalid mirror lock directory")
  }
  @gitops.repository_write_lock(directory)
}

///|
pub async fn save_push_mirror(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
  version : Int64,
  url : String,
  active : Bool,
  force_push : Bool,
  prune : Bool,
  config : RepoImportConfig?,
) -> Int64 {
  let scope = require_mirror_manager(pool, actor, repo)
  guard config is Some(config) else {
    raise @domain.BadRequest(
      message="SSH mirroring is not configured; ask an administrator to configure allowed destination hosts and SSH host keys",
    )
  }
  let target = parse_ssh_import_source(url.trim().to_owned())
  let credentials = team_import_credentials(
    config,
    repo.owner,
    identity_required=false,
  )
  authorize_import_source(credentials, target)
  // Configuration writes serialize with a claimed transfer. A busy transfer can be retried.
  let lock = mirror_lock(root, id)
  defer lock.close()
  ignore(require_mirror_manager(pool, actor, repo))
  if id != 0L {
    guard pool.with_client(client => {
      client.query_opt(
        "SELECT id FROM repository_mirror WHERE id=? AND repository_id=? AND version=?",
        params=[id, scope.id, version],
      )
      is Some(_)
    }) else {
      raise @domain.BadRequest(
        message="mirror changed or was removed; reload before saving",
      )
    }
  }
  let key = if id == 0L ||
    !pool.with_client(client => {
      client.query_opt(
        "SELECT mirror_id FROM mirror_ssh_key WHERE mirror_id=?",
        params=[id],
      )
      is Some(_)
    }) {
    Some(generate_mirror_key(root))
  } else {
    None
  }
  ignore(require_mirror_manager(pool, mirror_actor(pool, actor.id), repo))
  pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.query_opt(
          "SELECT id FROM repository_mirror WHERE repository_id=? AND url=? AND id<>?",
          params=[scope.id, target.url, id],
        )
        is None else {
        raise @domain.BadRequest(
          message="this mirror destination already exists",
        )
      }
      let saved = if id == 0L {
        guard tx
          .query_all("SELECT id FROM repository_mirror WHERE repository_id=?", params=[
            scope.id,
          ])
          .length() <
          5 else {
          raise @domain.BadRequest(
            message="a repository supports up to five push mirrors",
          )
        }
        tx
        .query_one(
          "INSERT INTO repository_mirror(repository_id,creator_id,url,active,force_push,prune,status) VALUES(?,?,?,?,?,?,?) RETURNING id",
          params=[
            scope.id,
            actor.id,
            target.url,
            active,
            force_push,
            prune,
            if active {
              "pending"
            } else {
              "disabled"
            },
          ],
        )
        .get_name("id")
      } else {
        guard tx.query_opt(
            "UPDATE repository_mirror SET creator_id=?,url=?,active=?,force_push=?,prune=?,version=version+1,generation=generation+1,status=?,attempts=0,next_attempt_at=datetime('now'),last_error='',lease=NULL,locked_at=NULL WHERE id=? AND repository_id=? AND version=? RETURNING id",
            params=[
              actor.id,
              target.url,
              active,
              force_push,
              prune,
              if active {
                "pending"
              } else {
                "disabled"
              },
              id,
              scope.id,
              version,
            ],
          )
          is Some(row) else {
          raise @domain.BadRequest(
            message="mirror changed or was removed; reload before saving",
          )
        }
        (row.get_name("id") : Int64)
      }
      if key is Some(key) {
        ignore(
          tx.execute(
            "INSERT INTO mirror_ssh_key(mirror_id,private_key,public_key) VALUES(?,?,?)",
            params=[saved, key.private_key, key.public_key],
          ),
        )
      }
      ignore(
        tx.execute(
          "INSERT INTO repository_audit(repository_id,actor_id,kind,detail) VALUES(?,?,'push_mirror',?)",
          params=[scope.id, actor.id, saved.to_string()],
        ),
      )
      saved
    })
  })
}

///|
pub async fn push_mirror_action(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
  version : Int64,
  action : String,
) -> Unit {
  let scope = require_mirror_manager(pool, actor, repo)
  let lock = mirror_lock(root, id)
  defer lock.close()
  ignore(require_mirror_manager(pool, actor, repo))
  pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.query_opt(
          "SELECT active FROM repository_mirror WHERE id=? AND repository_id=? AND version=?",
          params=[id, scope.id, version],
        )
        is Some(row) else {
        raise @domain.BadRequest(
          message="mirror changed or was removed; reload before continuing",
        )
      }
      if action == "delete" {
        ignore(
          tx.execute("DELETE FROM repository_mirror WHERE id=?", params=[id]),
        )
      } else {
        guard action == "sync" && (row.get_name("active") : Bool) else {
          raise @domain.BadRequest(message="enable the mirror before syncing")
        }
        ignore(
          tx.execute(
            "UPDATE repository_mirror SET generation=generation+1,version=version+1,status='pending',attempts=0,next_attempt_at=datetime('now'),last_error='',lease=NULL,locked_at=NULL WHERE id=?",
            params=[id],
          ),
        )
      }
      ignore(
        tx.execute(
          "INSERT INTO repository_audit(repository_id,actor_id,kind,detail) VALUES(?,?,'push_mirror_action',?)",
          params=[scope.id, actor.id, action + ":" + id.to_string()],
        ),
      )
    })
  })
}
