///|
pub fn pipeline_push_enabled(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> Bool raise {
  let scope = repository_scope(pool, actor, repo)
  pool.with_client(client => {
    client
    .query_one("SELECT pipeline_push_enabled FROM repository WHERE id = ?", params=[
      scope.id,
    ])
    .get_name("pipeline_push_enabled")
  })
}

///|
pub async fn set_pipeline_push_enabled(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  enabled : Bool,
) -> Unit {
  with_repository_write(pool, root, actor, repo, (scope, _) => {
    guard @identity.can_manage_team(pool, actor, scope.team_id) else {
      raise @domain.Forbidden(message="repository owner or admin required")
    }
    pool.with_client(client => {
      client.with_transaction(tx => {
        ignore(
          tx.execute(
            "UPDATE repository SET pipeline_push_enabled = ? WHERE id = ?",
            params=[enabled, scope.id],
          ),
        )
        ignore(
          tx.execute(
            "INSERT INTO repository_audit (repository_id, actor_id, kind, detail) VALUES (?, ?, 'pipeline_push', ?)",
            params=[scope.id, actor.id, enabled.to_string()],
          ),
        )
      })
    })
  })
}

///|
// Called by Git's trusted reference-transaction hook while the SSH parent owns
// the repository write lock. Prepared intents precede Git's reference commit.
pub fn record_received_transaction(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  source_key : String,
  phase : String,
  updates : String,
) -> Unit raise {
  let scope = repository_scope(pool, actor, repo)
  guard source_key.length() == 32 &&
    source_key.iter().all(ch => ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f')) else {
    raise @domain.BadRequest(message="invalid push transaction")
  }
  guard ["preparing", "prepared", "committed", "aborted"].contains(phase) else {
    raise @domain.BadRequest(message="invalid reference transaction phase")
  }
  // Newer Git versions call this before acquiring ref locks. The durable
  // intent belongs to prepared, which is also supported by older Git versions.
  if phase == "preparing" {
    return
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      check_release_tag_updates(tx, scope.id, phase, updates)
      record_mirror_refs(tx, scope.id, source_key, phase, updates)
      record_webhook_refs(tx, scope, actor.id, source_key, phase, updates)
      let enabled : Bool = tx
        .query_one(
          "SELECT (pipeline_push_enabled OR EXISTS (SELECT 1 FROM branch_required_check b WHERE b.repository_id = repository.id) OR EXISTS (SELECT 1 FROM merge_request m WHERE m.repository_id = repository.id AND m.status = 'open')) AS pipeline_push_enabled FROM repository WHERE id = ?",
          params=[scope.id],
        )
        .get_name("pipeline_push_enabled")
      for line in @domain.split_lines(updates) {
        let fields = line.split(" ").map(part => part.to_owned()).collect()
        guard fields.length() == 3 else {
          raise @domain.BadRequest(message="invalid ref update")
        }
        let reference = fields[2]
        if !reference.has_prefix("refs/heads/") {
          continue
        }
        guard @gitops.valid_commit_sha(fields[0]) &&
          @gitops.valid_commit_sha(fields[1]) else {
          raise @domain.BadRequest(message="invalid ref update")
        }
        if fields[1].iter().all(ch => ch == '0') || fields[0] == fields[1] {
          continue
        }
        if phase == "prepared" {
          if !enabled {
            continue
          }
          // Automatic execution does not broaden the existing manager-only run policy.
          guard @identity.can_manage_team(pool, actor, scope.team_id) else {
            continue
          }
          ignore(
            tx.execute(
              "INSERT INTO repository_ref_event (repository_id, actor_id, source_key, reference, old_sha, new_sha, state) VALUES (?, ?, ?, ?, ?, ?, 'prepared')",
              params=[
                scope.id,
                actor.id,
                source_key,
                reference,
                fields[0],
                fields[1],
              ],
            ),
          )
        } else {
          ignore(
            tx.execute(
              "UPDATE repository_ref_event SET state = ? WHERE repository_id = ? AND source_key = ? AND reference = ? AND old_sha = ? AND new_sha = ? AND state = 'prepared'",
              params=[
                phase,
                scope.id,
                source_key,
                reference,
                fields[0],
                fields[1],
              ],
            ),
          )
        }
      }
    })
  })
}

///|
// The merge receipt already pins the result, including after a server crash.
pub fn record_merged_ref(
  tx : @database.DbTransaction,
  repository_id : Int64,
  actor_id : Int64,
  merge_id : Int64,
  branch : String,
  sha : String,
) -> Unit raise {
  ignore(
    tx.execute(
      "INSERT OR IGNORE INTO repository_ref_event (repository_id, actor_id, source_key, reference, old_sha, new_sha, pin_ref, state) SELECT id, ?, ?, ?, '', ?, ?, 'ready' FROM repository WHERE id = ? AND (pipeline_push_enabled = 1 OR EXISTS (SELECT 1 FROM branch_required_check b WHERE b.repository_id = repository.id) OR EXISTS (SELECT 1 FROM merge_request m WHERE m.repository_id = repository.id AND m.status = 'open'))",
      params=[
        actor_id,
        "merge:" + merge_id.to_string(),
        "refs/heads/" + branch,
        sha,
        "refs/moonhub/merges/" + merge_id.to_string(),
        repository_id,
      ],
    ),
  )
}

///|
pub async fn recover_ref_events_locked(
  pool : @database.Database,
  scope : RepositoryScope,
  git_dir : String,
) -> Unit {
  recover_mirror_refs_locked(pool, scope, git_dir)
  recover_webhook_refs_locked(pool, scope, git_dir)
  let rows = pool.with_client(client => {
    client.query_all(
      "SELECT * FROM repository_ref_event WHERE repository_id = ? AND state IN ('prepared', 'committed') ORDER BY id",
      params=[scope.id],
    )
  })
  for row in rows {
    let id : Int64 = row.get_name("id")
    let sha : String = row.get_name("new_sha")
    if (row.get_name("state") : String) == "prepared" {
      let reference : String = row.get_name("reference")
      let (code, value) = @gitops.merge_git_command(git_dir, [
        "rev-parse", "--verify", "--quiet", reference,
      ])
      let current = value.trim().to_owned()
      let old : String = row.get_name("old_sha")
      if (code == 1 && old.iter().all(ch => ch == '0')) ||
        (code == 0 && current == old) {
        pool.with_client(client => {
          ignore(
            client.execute(
              "UPDATE repository_ref_event SET state = 'aborted' WHERE id = ?",
              params=[id],
            ),
          )
        })
        continue
      }
      guard code == 0 && current == sha else {
        raise @domain.BadRequest(
          message="unconfirmed push event; inspect repository refs before further writes",
        )
      }
    }
    let pin = "refs/moonhub/push-events/" + id.to_string()
    ignore(@gitops.merge_git(git_dir, ["update-ref", "--no-deref", pin, sha]))
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE repository_ref_event SET state = 'ready', pin_ref = ? WHERE id = ?",
          params=[pin, id],
        ),
      )
    })
  }
}
