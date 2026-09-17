///|
pub suberror ExecutionError {
  Conflict(String)
  LogLimit
}

///|
pub struct Coordinator {
  priv pool : @database.Database
  priv clock : () -> Int64
}

///|
pub fn Coordinator::new(
  pool : @database.Database,
  clock? : () -> Int64 = () => @env.now().reinterpret_as_int64(),
) -> Coordinator {
  { pool, clock, }
}

///|
pub struct Provider {
  id : Int64
  name : String
} derive(Debug)

///|
fn check_token(token : String) -> Unit raise {
  guard token.length() == 64 &&
    token.iter().all(ch => ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f')) else {
    raise @domain.Unauthorized(message="invalid runner credentials")
  }
}

///|
fn require_provider_admin(
  pool : @database.Database,
  actor : @domain.CurrentUser,
) -> Unit raise {
  let current = @identity.active_user_by_name(pool, actor.name_key)
  guard current.id == actor.id && current.is_site_admin else {
    raise @domain.Forbidden(
      message="site administrator required to manage providers",
    )
  }
}

///|
pub fn Coordinator::create_provider(
  self : Coordinator,
  actor : @domain.CurrentUser,
  name : String,
  token : String,
  labels : Array[String],
  repositories : Array[@domain.RepoId],
) -> Provider raise {
  require_provider_admin(self.pool, actor)
  check_token(token)
  guard @domain.valid_segment(name) && name.length() <= 64 else {
    raise @domain.BadRequest(message="invalid provider name")
  }
  let labels = labels.map(label => label.to_lower())
  guard labels.contains("self-hosted") &&
    labels.contains("linux") &&
    labels.length() <= 8 &&
    labels.all(label => {
      !label.is_empty() &&
      label.length() <= 64 &&
      label
      .iter()
      .all(ch => {
        ch.is_ascii_alphabetic() ||
        ch.is_ascii_digit() ||
        ch == '_' ||
        ch == '-'
      })
    }) else {
    raise @domain.BadRequest(message="invalid provider labels")
  }
  let repository_ids = repositories.map(repo => {
    @repository.repository_scope(self.pool, actor, repo).id
  })
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        guard tx.query_opt(
            "SELECT id FROM pipeline_provider WHERE name = ? OR token_hash = ? LIMIT 1",
            params=[name, @identity.hash_token(token)],
          )
          is None &&
          tx.query_opt(
            "SELECT id FROM pipeline_job_attempt WHERE token_hash = ?",
            params=[@identity.hash_token(token)],
          )
          is None else {
          raise Conflict("provider name or credential already exists")
        }
        let id : Int64 = tx
          .query_one(
            "INSERT INTO pipeline_provider (name, token_hash) VALUES (?, ?) RETURNING id",
            params=[name, @identity.hash_token(token)],
          )
          .get_name("id")
        for label in labels {
          let _ = tx.execute(
            "INSERT OR IGNORE INTO pipeline_provider_label (provider_id, label) VALUES (?, ?)",
            params=[id, label],
          )
        }
        for repository_id in repository_ids {
          let _ = tx.execute(
            "INSERT OR IGNORE INTO pipeline_provider_repository (provider_id, repository_id) VALUES (?, ?)",
            params=[id, repository_id],
          )
        }
        { id, name, }
      },
      immediate=true,
    )
  })
}

///|
fn authenticate_provider(
  tx : @database.DbTransaction,
  token : String,
) -> @database.DbRow raise {
  check_token(token)
  let row = tx.query_opt(
    "SELECT * FROM pipeline_provider WHERE token_hash = ? AND revoked = 0",
    params=[@identity.hash_token(token)],
  )
  guard row is Some(row) else {
    raise @domain.Unauthorized(message="invalid runner credentials")
  }
  row
}

///|
pub fn Coordinator::authenticate_provider(
  self : Coordinator,
  token : String,
) -> Unit raise {
  self.pool.with_client(client => {
    client.with_transaction(tx => ignore(authenticate_provider(tx, token)))
  })
}

///|
pub fn Coordinator::set_provider_paused(
  self : Coordinator,
  actor : @domain.CurrentUser,
  id : Int64,
  paused : Bool,
) -> Unit raise {
  require_provider_admin(self.pool, actor)
  self.pool.with_client(client => {
    guard client.execute(
        "UPDATE pipeline_provider SET paused = ? WHERE id = ? AND revoked = 0",
        params=[paused, id],
      ) ==
      1 else {
      raise @domain.NotFound(message="provider not found")
    }
  })
}

///|
pub fn Coordinator::revoke_provider(
  self : Coordinator,
  actor : @domain.CurrentUser,
  id : Int64,
) -> Unit raise {
  require_provider_admin(self.pool, actor)
  let now = (self.clock)()
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        guard tx.execute(
            "UPDATE pipeline_provider SET revoked = 1 WHERE id = ?",
            params=[id],
          ) ==
          1 else {
          raise @domain.NotFound(message="provider not found")
        }
        let _ = tx.execute(
          "UPDATE pipeline_job_attempt SET cancel_at_ms = COALESCE(cancel_at_ms, ?) WHERE provider_id = ? AND status <> 'completed'",
          params=[now, id],
        )
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::set_provider_repository(
  self : Coordinator,
  actor : @domain.CurrentUser,
  provider_id : Int64,
  repo : @domain.RepoId,
  allowed : Bool,
) -> Unit raise {
  require_provider_admin(self.pool, actor)
  let scope = @repository.repository_scope(self.pool, actor, repo)
  let now = (self.clock)()
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        guard tx.query_opt(
            "SELECT id FROM pipeline_provider WHERE id = ? AND revoked = 0",
            params=[provider_id],
          )
          is Some(_) else {
          raise @domain.NotFound(message="provider not found")
        }
        if allowed {
          let _ = tx.execute(
            "INSERT OR IGNORE INTO pipeline_provider_repository (provider_id, repository_id) VALUES (?, ?)",
            params=[provider_id, scope.id],
          )
        } else {
          let _ = tx.execute(
            "DELETE FROM pipeline_provider_repository WHERE provider_id = ? AND repository_id = ?",
            params=[provider_id, scope.id],
          )
          let _ = tx.execute(
            "UPDATE pipeline_job_attempt SET cancel_at_ms = COALESCE(cancel_at_ms, ?) WHERE provider_id = ? AND status <> 'completed' AND job_id IN (SELECT j.id FROM pipeline_job j JOIN pipeline_run r ON r.id = j.run_id WHERE r.repository_id = ?)",
            params=[now, provider_id, scope.id],
          )
        }
      },
      immediate=true,
    )
  })
}
