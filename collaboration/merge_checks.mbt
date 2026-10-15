///|
pub struct MergeCheck {
  workflow_path : String
  required : Bool
  state : String
  conclusion : String
  run_number : Int64?
  error : String
}

///|
pub fn required_merge_checks(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  branch : String,
) -> Array[String] raise {
  pool.with_client(client => {
    client
    .query_all(
      "SELECT workflow_path FROM branch_required_check WHERE repository_id = ? AND branch = ? ORDER BY workflow_path",
      params=[scope.id, branch],
    )
    .map(row => row.get_name("workflow_path"))
  })
}

///|
pub fn merge_checks(
  pool : @database.Database,
  mr : MergeRequest,
  version? : Int64,
) -> Array[MergeCheck] raise {
  let version = version.unwrap_or(mr.version)
  pool.with_client(client => {
    client
    .query_all(
      "SELECT c.* FROM merge_check c JOIN merge_request m ON m.id = c.merge_request_id WHERE c.merge_request_id = ? AND c.version = ? AND c.generation = CASE WHEN c.version = m.current_version THEN m.check_generation ELSE (SELECT MAX(n.generation) FROM merge_check n WHERE n.merge_request_id = c.merge_request_id AND n.version = c.version) END ORDER BY c.workflow_path",
      params=[mr.id, version],
    )
    .map(row => {
      workflow_path: row.get_name("workflow_path"),
      required: !(row.get_name("automatic") : Bool),
      state: row.get_name("state"),
      conclusion: row.get_name("conclusion"),
      run_number: row.get_name("run_number"),
      error: row.get_name("last_error"),
    })
  })
}

///|
// Call under the repository write lock. An explicit manager approves this exact
// comparison; otherwise only a durable manager push of the source can authorize it.
pub fn prepare_merge_checks(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  mr : MergeRequest,
  actor? : @domain.CurrentUser,
  workflows~ : Array[String] = [],
) -> Unit raise {
  guard mr.repository_id == scope.id else {
    raise @domain.NotFound(message="merge request not found")
  }
  if mr.status != "open" || mr.draft || mr.version == 0L {
    return
  }
  let revision = merge_revision(pool, mr)
  let mut approved_by = 0L
  if actor is Some(actor) &&
    @identity.can_manage_team(pool, actor, scope.team_id) &&
    @repository.can_access_repository(pool, actor, scope.repo, Write) {
    approved_by = actor.id
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      if approved_by == 0L {
        if tx.query_opt(
            "SELECT e.actor_id FROM repository_ref_event e JOIN \"user\" u ON u.id = e.actor_id LEFT JOIN team_member tm ON tm.user_id = u.id AND tm.team_id = ? WHERE e.repository_id = ? AND e.reference = ? AND e.new_sha = ? AND e.state IN ('ready', 'processed') AND u.status = 'active' AND (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin')) ORDER BY e.id DESC LIMIT 1",
            params=[
              scope.team_id,
              scope.id,
              "refs/heads/" + mr.source,
              revision.source_sha,
            ],
          )
          is Some(row) {
          approved_by = row.get_name("actor_id")
        }
      }
      let generation : Int64 = tx
        .query_one("SELECT check_generation FROM merge_request WHERE id = ?", params=[
          mr.id,
        ])
        .get_name("check_generation")
      if approved_by != 0L {
        ignore(
          tx.execute(
            "INSERT OR IGNORE INTO merge_execution_approval (merge_request_id, generation, source_sha, user_id) VALUES (?, ?, ?, ?)",
            params=[mr.id, generation, revision.source_sha, approved_by],
          ),
        )
      }
      // A target advance requires new results, but not renewed permission to
      // execute the identical source within this ready/reopen generation.
      if approved_by == 0L {
        if tx.query_opt(
            "SELECT a.user_id AS requested_by_user_id FROM merge_execution_approval a JOIN \"user\" u ON u.id = a.user_id LEFT JOIN team_member tm ON tm.user_id = u.id AND tm.team_id = ? WHERE a.merge_request_id = ? AND a.generation = ? AND a.source_sha = ? AND u.status = 'active' AND (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin')) ORDER BY a.user_id LIMIT 1",
            params=[scope.team_id, mr.id, generation, revision.source_sha],
          )
          is Some(row) {
          approved_by = row.get_name("requested_by_user_id")
        }
      }
      let paths = tx.query_all(
        "SELECT workflow_path FROM branch_required_check WHERE repository_id = ? AND branch = ?",
        params=[scope.id, mr.target],
      )
      let required : Array[String] = paths.map(row => {
        row.get_name("workflow_path")
      })
      let selected = required.copy()
      for path in workflows {
        if !selected.contains(path) {
          selected.push(path)
        }
      }
      for
        row in tx.query_all(
          "SELECT workflow_path FROM merge_check WHERE merge_request_id = ? AND version = ? AND generation = ?",
          params=[mr.id, mr.version, generation],
        ) {
        let path : String = row.get_name("workflow_path")
        if !selected.contains(path) {
          selected.push(path)
        }
      }
      for path in selected {
        ignore(
          tx.execute(
            "INSERT OR IGNORE INTO merge_check (merge_request_id, version, generation, workflow_path, automatic) VALUES (?, ?, ?, ?, ?)",
            params=[
              mr.id,
              mr.version,
              generation,
              path,
              !required.contains(path),
            ],
          ),
        )
        if approved_by != 0L {
          ignore(
            tx.execute(
              "UPDATE merge_check SET requested_by_user_id = ?, state = 'pending', last_error = '', retry_after = 0 WHERE merge_request_id = ? AND version = ? AND generation = ? AND workflow_path = ? AND (state = 'awaiting_approval' OR (state = 'error' AND ?))",
              params=[
                approved_by,
                mr.id,
                mr.version,
                generation,
                path,
                actor is Some(_),
              ],
            ),
          )
        }
      }
    })
  })
}

///|
pub fn approve_merge_checks(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  version : Int64,
) -> Unit raise {
  @repository.authorize_repository(pool, actor, scope.repo, Write)
  let mr = require_merge_request(pool, scope, mr.number)
  guard @identity.can_manage_team(pool, actor, scope.team_id) else {
    raise @domain.Forbidden(
      message="repository owner or admin required to approve checks",
    )
  }
  require_mutable_merge(mr)
  guard mr.status == "open" && !mr.draft && mr.version == version else {
    raise @domain.BadRequest(
      message="Reload and approve the current ready merge request version.",
    )
  }
  prepare_merge_checks(pool, scope, mr, actor~)
  pool.with_client(client => {
    client.with_transaction(tx => {
      ignore(
        tx.execute(
          "UPDATE merge_request SET checks_poll_after = 0 WHERE id = ?",
          params=[mr.id],
        ),
      )
      merge_activity(tx, mr, actor.id, "checks_approved")
    })
  })
}

///|
fn merge_checks_blocker(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  mr : MergeRequest,
) -> String raise {
  pool.with_client(client => {
    guard client.query_opt(
        "SELECT id FROM merge_request WHERE id = ? AND repository_id = ? AND current_version = ?",
        params=[mr.id, scope.id, mr.version],
      )
      is Some(_) else {
      return "Merge request version changed; reload before merging."
    }
    let missing = client.query_opt(
      "SELECT b.workflow_path FROM branch_required_check b WHERE b.repository_id = ? AND b.branch = ? AND NOT EXISTS (SELECT 1 FROM merge_check c JOIN merge_request m ON m.id = c.merge_request_id WHERE c.merge_request_id = ? AND c.version = m.current_version AND c.generation = m.check_generation AND c.workflow_path = b.workflow_path AND c.state = 'completed' AND c.conclusion = 'success') ORDER BY b.workflow_path LIMIT 1",
      params=[scope.id, mr.target, mr.id],
    )
    match missing {
      Some(row) =>
        "Required check has not passed: " +
        (row.get_name("workflow_path") : String)
      None => ""
    }
  })
}
