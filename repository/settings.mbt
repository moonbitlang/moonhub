///|
pub struct RepositorySettings {
  scope : RepositoryScope
  visibility : String
}

///|
pub fn repository_settings(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> RepositorySettings raise {
  pool.with_client(client => {
    let row = client.query_opt(
      "SELECT r.id,r.team_id,r.visibility,u.is_site_admin,m.role FROM repository r JOIN team t ON t.id=r.team_id JOIN \"user\" u ON u.id=? AND u.status='active' LEFT JOIN team_member m ON m.team_id=r.team_id AND m.user_id=u.id WHERE t.name_key=? AND r.name=? AND r.ready=1",
      params=[actor.id, repo.owner, repo.name],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="repository not found or access denied")
    }
    let admin : Bool = row.get_name("is_site_admin")
    let role : String? = row.get_name("role")
    let visibility : String = row.get_name("visibility")
    guard admin || role is Some(_) || visibility == "public" else {
      raise @domain.NotFound(message="repository not found or access denied")
    }
    guard admin || role is Some("owner" | "admin") else {
      raise @domain.Forbidden(message="repository owner or admin required")
    }
    {
      scope: { id: row.get_name("id"), team_id: row.get_name("team_id"), repo, },
      visibility,
    }
  })
}

///|
fn check_settings_identity(
  settings : RepositorySettings,
  id : Int64,
) -> Unit raise {
  guard settings.scope.id == id else {
    raise @domain.BadRequest(
      message="repository has changed; reload its settings",
    )
  }
}

///|
pub async fn change_repository_visibility(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
  previous : String,
  target : String,
) -> Unit {
  let initial = repository_settings(pool, actor, repo)
  check_settings_identity(initial, id)
  let expected = initial.scope
  guard (previous == "private" && target == "public") ||
    (previous == "public" && target == "private") else {
    raise @domain.BadRequest(message="invalid visibility change")
  }
  let lock = repository_write_lock(root, repo)
  defer lock.close()
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        let current = repository_settings(pool, actor, repo)
        require_current_scope(pool, expected)
        check_settings_identity(current, id)
        guard current.visibility == previous else {
          raise @domain.BadRequest(
            message="visibility has changed; review a new confirmation",
          )
        }
        ignore(
          tx.execute(
            "UPDATE repository SET visibility=?, updated_at=datetime('now') WHERE id=?",
            params=[target, id],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
fn require_repository_idle(
  client : @database.DbClient,
  id : Int64,
) -> Unit raise {
  guard client.query_opt(
      "SELECT id FROM pipeline_run WHERE repository_id=? AND status<>'completed' LIMIT 1",
      params=[id],
    )
    is None else {
    raise @domain.BadRequest(
      message="Actions are unfinished. Cancel them or wait for completion, then retry.",
    )
  }
  guard client.query_opt(
      "SELECT id FROM repository_mirror WHERE repository_id=? AND status='syncing' LIMIT 1",
      params=[id],
    )
    is None else {
    raise @domain.BadRequest(
      message="A mirror is syncing. Wait for it to finish, then retry.",
    )
  }
  guard client.query_opt(
      "SELECT d.id FROM webhook_delivery d JOIN repository_webhook h ON h.id=d.webhook_id WHERE h.repository_id=? AND d.status='sending' LIMIT 1",
      params=[id],
    )
    is None else {
    raise @domain.BadRequest(
      message="A webhook is being sent. Wait for delivery to finish, then retry.",
    )
  }
}

///|
pub async fn delete_repository(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
  confirmation : String,
) -> Unit {
  let initial = repository_settings(pool, actor, repo)
  check_settings_identity(initial, id)
  let expected = initial.scope
  guard confirmation == repo.path() else {
    raise @domain.BadRequest(
      message="Enter the full repository name exactly: \{repo.path()}",
    )
  }
  pool.with_client(client => require_repository_idle(client, id))
  let lock = repository_write_lock(root, repo)
  defer lock.close()
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        check_settings_identity(repository_settings(pool, actor, repo), id)
        require_current_scope(pool, expected)
        // The write reservation also serializes worker claims with this check.
        require_repository_idle(client, id)
        ignore(
          tx.execute(
            "INSERT INTO repository_file_garbage(repository_id,owner,name,kind,resource_id,path) VALUES(?,?,?,'git',?,?)",
            params=[id, repo.owner, repo.name, id, "\{repo.path()}.git"],
          ),
        )
        ignore(
          tx.execute(
            "INSERT INTO repository_file_garbage(repository_id,owner,name,kind,resource_id,path) SELECT repository_id,?,?,'mirror',id,'.mirrors/' || id FROM repository_mirror WHERE repository_id=?",
            params=[repo.owner, repo.name, id],
          ),
        )
        // Cascades journal Actions/Cache/Release bytes; the deploy-key trigger revokes keys.
        ignore(tx.execute("DELETE FROM repository WHERE id=?", params=[id]))
      },
      immediate=true,
    )
  })
}

///|
fn require_repository_name_available(
  client : @database.DbClient,
  repo : @domain.RepoId,
) -> Unit raise {
  guard client.query_opt(
      "SELECT id FROM repository_file_garbage WHERE owner=? AND name=? AND kind='git'",
      params=[repo.owner, repo.name],
    )
    is None else {
    raise @domain.BadRequest(
      message="repository files are still being deleted; retry later",
    )
  }
  guard client.query_opt(
      "SELECT x.repository_id FROM repository_transfer x JOIN team t ON t.id=x.target_team_id WHERE t.name_key=? AND x.name=?",
      params=[repo.owner, repo.name],
    )
    is None else {
    raise @domain.BadRequest(
      message="repository name is reserved by an unfinished transfer; retry later",
    )
  }
}
