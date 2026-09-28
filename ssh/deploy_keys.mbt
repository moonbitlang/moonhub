///|
pub struct DeployKey {
  id : Int64
  title : String
  fingerprint : String
  write_access : Bool
  creator : String
  created_at : String
  last_used_at : String?
  revoked_at : String?
}

///|
pub fn require_deploy_key_manager(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> @repository.RepositoryScope raise {
  let scope = @repository.repository_scope(pool, actor, repo)
  guard @identity.can_manage_team(pool, actor, scope.team_id) else {
    raise @domain.Forbidden(message="repository owner or admin required")
  }
  scope
}

///|
pub fn repository_deploy_keys(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> Array[DeployKey] raise {
  let scope = require_deploy_key_manager(pool, actor, repo)
  pool.with_client(client => {
    client
    .query_all(
      (
        #|SELECT k.*, u.name_key AS creator FROM repository_deploy_key k
        #|JOIN "user" u ON u.id = k.creator_id WHERE k.repository_id = ?
        #|ORDER BY (k.revoked_at IS NOT NULL), k.id DESC
      ),
      params=[scope.id],
    )
    .map(row => {
      id: row.get_name("id"),
      title: row.get_name("title"),
      fingerprint: row.get_name("fingerprint"),
      write_access: row.get_name("write_access"),
      creator: row.get_name("creator"),
      created_at: row.get_name("created_at"),
      last_used_at: row.get_name("last_used_at"),
      revoked_at: row.get_name("revoked_at"),
    })
  })
}

///|
pub fn add_repository_deploy_key(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  title : String,
  key : SshPublicKey,
  write_access? : Bool = false,
) -> Int64 raise {
  let title = title.trim().to_owned()
  guard !title.is_empty() && title.length() <= 200 else {
    raise @domain.BadRequest(
      message="key title must contain 1 to 200 characters",
    )
  }
  let key = parse_ssh_public_key(key.public_key)
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        let scope = require_deploy_key_manager(pool, actor, repo)
        require_unused_public_key(tx, key)
        let id : Int64 = tx
          .query_one(
            "INSERT INTO repository_deploy_key (repository_id, title, public_key, fingerprint, write_access, creator_id) VALUES (?, ?, ?, ?, ?, ?) RETURNING id",
            params=[
              scope.id,
              title,
              key.public_key,
              key.fingerprint,
              write_access,
              actor.id,
            ],
          )
          .get_name("id")
        ignore(
          tx.execute(
            "INSERT INTO repository_audit (repository_id, actor_id, kind, detail) VALUES (?, ?, 'deploy_key_added', ?)",
            params=[
              scope.id,
              actor.id,
              "key=\{id}; fingerprint=\{key.fingerprint}; write_access=\{write_access}",
            ],
          ),
        )
        id
      },
      immediate=true,
    )
  })
}

///|
pub fn set_repository_deploy_key_access(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  key_id : Int64,
  write_access : Bool,
) -> Unit raise {
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        let scope = require_deploy_key_manager(pool, actor, repo)
        let row = tx.query_opt(
          "SELECT write_access FROM repository_deploy_key WHERE id = ? AND repository_id = ? AND revoked_at IS NULL",
          params=[key_id, scope.id],
        )
        guard row is Some(row) else {
          raise @domain.NotFound(message="active deploy key not found")
        }
        let previous : Bool = row.get_name("write_access")
        if previous == write_access {
          return
        }
        ignore(
          tx.execute(
            "UPDATE repository_deploy_key SET write_access = ? WHERE id = ?",
            params=[write_access, key_id],
          ),
        )
        ignore(
          tx.execute(
            "INSERT INTO repository_audit (repository_id, actor_id, kind, detail) VALUES (?, ?, 'deploy_key_access_changed', ?)",
            params=[
              scope.id,
              actor.id,
              "key=\{key_id}; write_access=\{previous}->\{write_access}",
            ],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
pub fn revoke_repository_deploy_key(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  key_id : Int64,
) -> Unit raise {
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        let scope = require_deploy_key_manager(pool, actor, repo)
        let changed = tx.execute(
          "UPDATE repository_deploy_key SET revoked_at = datetime('now') WHERE id = ? AND repository_id = ? AND revoked_at IS NULL",
          params=[key_id, scope.id],
        )
        guard changed == 1 else {
          raise @domain.NotFound(message="active deploy key not found")
        }
        ignore(
          tx.execute(
            "INSERT INTO repository_audit (repository_id, actor_id, kind, detail) VALUES (?, ?, 'deploy_key_revoked', ?)",
            params=[scope.id, actor.id, "key=\{key_id}"],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
fn require_unused_public_key(
  tx : @database.DbTransaction,
  key : SshPublicKey,
) -> Unit raise {
  guard tx.query_opt(
      (
        #|SELECT 1 FROM ssh_key WHERE fingerprint = ? OR public_key = ?
        #|UNION ALL SELECT 1 FROM repository_deploy_key WHERE fingerprint = ? OR public_key = ? LIMIT 1
      ),
      params=[key.fingerprint, key.public_key, key.fingerprint, key.public_key],
    )
    is None else {
    raise @domain.BadRequest(
      message="this public key is already registered (possibly revoked); use a new key",
    )
  }
}
