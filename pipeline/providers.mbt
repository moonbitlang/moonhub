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
  paused : Bool
  revoked : Bool
  labels : Array[String]
  scope : ProviderScope
  repositories : Array[String]
  last_seen_ms : Int64?
  online : Bool
} derive(Debug)

///|
pub enum ProviderScope {
  SelectedRepositories
  AllRepositories
} derive(Eq, Debug)

///|
pub fn ProviderScope::parse(value : String) -> ProviderScope raise {
  match value {
    "selected" => SelectedRepositories
    "all" => AllRepositories
    _ =>
      raise @domain.BadRequest(
        message="Provider scope must be selected or all.",
      )
  }
}

///|
pub fn ProviderScope::value(self : ProviderScope) -> String {
  match self {
    SelectedRepositories => "selected"
    AllRepositories => "all"
  }
}

///|
let provider_contact_window_ms : Int64 = 60000L

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
fn provider_from_row(
  client : @database.DbClient,
  row : @database.DbRow,
  now : Int64,
) -> Provider raise {
  let id : Int64 = row.get_name("id")
  let seen : Int64? = row.get_name("last_seen_ms")
  {
    id,
    name: row.get_name("name"),
    paused: row.get_name("paused"),
    revoked: row.get_name("revoked"),
    scope: ProviderScope::parse(row.get_name("repository_scope")),
    repositories: client
    .query_all(
      "SELECT t.name_key AS owner, r.name FROM pipeline_provider_repository g JOIN repository r ON r.id = g.repository_id JOIN team t ON t.id = r.team_id WHERE g.provider_id = ? ORDER BY t.name_key, r.name",
      params=[id],
    )
    .map(repo => {
      let owner : String = repo.get_name("owner")
      let name : String = repo.get_name("name")
      owner + "/" + name
    }),
    last_seen_ms: seen,
    online: seen is Some(seen) &&
    seen <= now &&
    now - seen < provider_contact_window_ms,
    labels: client
    .query_all(
      "SELECT label FROM pipeline_provider_label WHERE provider_id = ? ORDER BY label",
      params=[id],
    )
    .map(label => label.get_name("label")),
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
  scope? : ProviderScope = SelectedRepositories,
) -> Provider raise {
  require_provider_admin(self.pool, actor)
  check_token(token)
  guard @domain.valid_segment(name) && name.length() <= 64 else {
    raise @domain.BadRequest(message="invalid provider name")
  }
  let labels = normalize_provider_labels(labels)
  guard scope != AllRepositories || repositories.is_empty() else {
    raise @domain.BadRequest(
      message="All-repository scope cannot include a repository list.",
    )
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
            "INSERT INTO pipeline_provider (name, token_hash, repository_scope) VALUES (?, ?, ?) RETURNING id",
            params=[name, @identity.hash_token(token), scope.value()],
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
        provider_from_row(
          client,
          tx.query_one("SELECT * FROM pipeline_provider WHERE id = ?", params=[
            id,
          ]),
          (self.clock)(),
        )
      },
      immediate=true,
    )
  })
}

///|
fn normalize_provider_labels(labels : Array[String]) -> Array[String] raise {
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
    raise @domain.BadRequest(
      message="Use up to 8 labels (1-64 letters, digits, underscores or hyphens each), including self-hosted and linux.",
    )
  }
  labels
}

///|
pub fn Coordinator::set_provider_labels(
  self : Coordinator,
  actor : @domain.CurrentUser,
  id : Int64,
  labels : Array[String],
) -> Unit raise {
  require_provider_admin(self.pool, actor)
  let labels = normalize_provider_labels(labels)
  let now = (self.clock)()
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        guard tx.query_opt(
            "SELECT id FROM pipeline_provider WHERE id = ? AND revoked = 0",
            params=[id],
          )
          is Some(_) else {
          raise @domain.NotFound(message="provider not found")
        }
        let _ = tx.execute(
          "DELETE FROM pipeline_provider_label WHERE provider_id = ?",
          params=[id],
        )
        for label in labels {
          let _ = tx.execute(
            "INSERT OR IGNORE INTO pipeline_provider_label (provider_id, label) VALUES (?, ?)",
            params=[id, label],
          )
        }
        // Match claim's all-labels rule and cancel obsolete leases atomically.
        let _ = tx.execute(
          (
            #|UPDATE pipeline_job_attempt SET cancel_at_ms = COALESCE(cancel_at_ms, ?)
            #|WHERE provider_id = ? AND status <> 'completed'
            #|AND EXISTS (SELECT 1 FROM pipeline_job_label required
            #|  WHERE required.job_id = pipeline_job_attempt.job_id
            #|  AND NOT EXISTS (SELECT 1 FROM pipeline_provider_label current
            #|    WHERE current.provider_id = pipeline_job_attempt.provider_id AND current.label = required.label))
          ),
          params=[now, id],
        )
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::ensure_provider(
  self : Coordinator,
  actor : @domain.CurrentUser,
  name : String,
  token : String,
  labels : Array[String],
  repositories : Array[@domain.RepoId],
  scope? : ProviderScope? = None,
) -> Provider raise {
  require_provider_admin(self.pool, actor)
  check_token(token)
  guard @domain.valid_segment(name) && name.length() <= 64 else {
    raise @domain.BadRequest(message="invalid provider name")
  }
  let labels = normalize_provider_labels(labels)
  guard scope != Some(AllRepositories) || repositories.is_empty() else {
    raise @domain.BadRequest(
      message="All-repository scope cannot include a repository list.",
    )
  }
  let repository_ids = repositories.map(repo => {
    @repository.repository_scope(self.pool, actor, repo).id
  })
  let hash = @identity.hash_token(token)
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = match
          tx.query_opt("SELECT * FROM pipeline_provider WHERE name = ?", params=[
            name,
          ]) {
          Some(row) => {
            guard (row.get_name("token_hash") : String) == hash else {
              raise Conflict("provider name exists with a different credential")
            }
            guard !(row.get_name("revoked") : Bool) else {
              raise Conflict("provider is revoked")
            }
            row
          }
          None => {
            guard tx.query_opt(
                "SELECT id FROM pipeline_provider WHERE token_hash = ? UNION SELECT id FROM pipeline_job_attempt WHERE token_hash = ?",
                params=[hash, hash],
              )
              is None else {
              raise Conflict("provider credential is already in use")
            }
            tx.query_one(
              "INSERT INTO pipeline_provider (name, token_hash) VALUES (?, ?) RETURNING *",
              params=[name, hash],
            )
          }
        }
        let id : Int64 = row.get_name("id")
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
        if scope is Some(scope) {
          ignore(
            tx.execute(
              "UPDATE pipeline_provider SET repository_scope = ? WHERE id = ?",
              params=[scope.value(), id],
            ),
          )
          if scope == AllRepositories {
            ignore(
              tx.execute(
                "DELETE FROM pipeline_provider_repository WHERE provider_id = ?",
                params=[id],
              ),
            )
          }
          cancel_unscoped_attempts(tx, id, (self.clock)())
        }
        provider_from_row(
          client,
          tx.query_one("SELECT * FROM pipeline_provider WHERE id = ?", params=[
            id,
          ]),
          (self.clock)(),
        )
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::list_providers(
  self : Coordinator,
  actor : @domain.CurrentUser,
) -> Array[Provider] raise {
  require_provider_admin(self.pool, actor)
  self.pool.with_client(client => {
    client
    .query_all("SELECT * FROM pipeline_provider ORDER BY id")
    .map(row => provider_from_row(client, row, (self.clock)()))
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
            "SELECT repository_scope FROM pipeline_provider WHERE id = ? AND revoked = 0",
            params=[provider_id],
          )
          is Some(provider) else {
          raise @domain.NotFound(message="provider not found")
        }
        guard (provider.get_name("repository_scope") : String) == "selected" else {
          raise @domain.BadRequest(
            message="Select repository scope before changing individual grants.",
          )
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
