///|
pub async fn refresh_merge_request(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  git_dir : String,
  mr : MergeRequest,
) -> MergeRequest {
  if mr.status != "open" ||
    mr.job_status == "pending" ||
    mr.job_status == "running" {
    return mr
  }
  let comparison = @gitops.compare_branches(git_dir, mr.source, mr.target)
  let mut source_changed = false
  if mr.version > 0L {
    let previous = merge_revision(pool, mr)
    source_changed = previous.source_sha != comparison.source_sha
    if previous.source_sha == comparison.source_sha &&
      previous.target_sha == comparison.target_sha {
      // Bind a pending reopen to the first observed source, even when its
      // refs are unchanged. A later push must become synchronize independently
      // of when the Pipeline worker next discovers workflows.
      pool.with_client(client => {
        ignore(
          client.execute(
            "UPDATE merge_request SET workflow_event_pending = 0 WHERE id = ? AND workflow_event_pending = 1",
            params=[mr.id],
          ),
        )
      })
      return mr
    }
  }
  let (tree, reason) = (@gitops.merged_tree(git_dir, comparison), "") catch {
    @domain.BadRequest(message~) | @gitops.Failure(message~) => ("", message)
    err => raise err
  }
  let version = mr.version + 1L
  // Keep reviewed objects reachable even after branch deletion or force-push.
  ignore(
    @gitops.merge_git(
      git_dir,
      ["update-ref", "--stdin"],
      input="start\nverify refs/heads/\{mr.source} \{comparison.source_sha}\nverify refs/heads/\{mr.target} \{comparison.target_sha}\nupdate refs/moonhub/mr/\{mr.id}/\{version}/source \{comparison.source_sha}\nupdate refs/moonhub/mr/\{mr.id}/\{version}/target \{comparison.target_sha}\nprepare\ncommit\n",
    ),
  )
  pool.with_client(client => {
    client.with_transaction(tx => {
      let _ = tx.execute(
        "INSERT INTO merge_revision (merge_request_id, version, source_sha, target_sha, base_sha, merge_tree, block_reason) VALUES (?, ?, ?, ?, ?, ?, ?)",
        params=[
          mr.id,
          version,
          comparison.source_sha,
          comparison.target_sha,
          comparison.base_sha,
          tree,
          reason,
        ],
      )
      let _ = tx.execute(
        "UPDATE merge_request SET current_version = ?, workflow_event = CASE WHEN ? AND workflow_event_pending = 0 THEN 'synchronize' ELSE workflow_event END, workflow_event_pending = 0, checks_poll_after = 0, updated_at = datetime('now') WHERE id = ?",
        params=[version, source_changed, mr.id],
      )
      merge_activity(
        tx,
        { ..mr, version, },
        if mr.version == 0L {
          mr.author_id
        } else {
          0L
        },
        if mr.version == 0L {
          "opened"
        } else {
          "updated"
        },
      )
    })
  })
  require_merge_request(pool, scope, mr.number)
}

///|
pub async fn create_merge_request(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  git_dir : String,
  actor : @domain.CurrentUser,
  title : String,
  description : String,
  source : String,
  target : String,
  draft : Bool,
  issue~ : Int64 = 0L,
  authorize_checks~ : Bool = true,
) -> MergeRequest {
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
  let title = title.trim().to_owned()
  guard !title.is_empty() &&
    title.length() <= 200 &&
    description.length() <= 20000 else {
    raise @domain.BadRequest(
      message="title must be 1-200 characters and description at most 20000 characters",
    )
  }
  let comparison = @gitops.compare_branches(git_dir, source, target)
  let issue_id = if issue == 0L {
    0L
  } else {
    require_issue(pool, scope, issue).id
  }
  guard comparison.source_sha != comparison.base_sha else {
    raise @domain.BadRequest(message="source branch has no new commits")
  }
  let number : Int64 = pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.query_opt(
          "SELECT id FROM merge_request WHERE repository_id = ? AND source_branch = ? AND target_branch = ? AND status = 'open'",
          params=[scope.id, source, target],
        )
        is None else {
        raise @domain.BadRequest(
          message="an open merge request already exists for these branches",
        )
      }
      let row = tx.query_one(
        "SELECT COALESCE(MAX(number), 0) + 1 AS number FROM merge_request WHERE repository_id = ?",
        params=[scope.id],
      )
      let number : Int64 = row.get_name("number")
      let _ = tx.execute(
        "INSERT INTO merge_request (repository_id, number, author_id, title, description, source_branch, target_branch, draft, issue_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULLIF(?, 0))",
        params=[
          scope.id,
          number,
          actor.id,
          title,
          description,
          source,
          target,
          draft,
          issue_id,
        ],
      )
      let id : Int64 = tx
        .query_one("SELECT last_insert_rowid() AS id")
        .get_name("id")
      @attachments.replace_references(
        tx,
        scope.id,
        actor.id,
        MergeRequest(id),
        description,
      )
      number
    })
  })
  // A failed initial comparison must not leave an invisible duplicate reservation.
  errdefer pool.with_client(client => {
    let _ = client.execute(
      "DELETE FROM merge_request WHERE repository_id = ? AND number = ? AND current_version = 0",
      params=[scope.id, number],
    )
  })
  let created = refresh_merge_request(
    pool,
    scope,
    git_dir,
    require_merge_request(pool, scope, number),
  )
  if authorize_checks {
    prepare_merge_checks(pool, scope, created, actor~)
  } else {
    prepare_merge_checks(pool, scope, created)
  }
  created
}

///|
fn require_mutable_merge(mr : MergeRequest) -> Unit raise {
  guard mr.status != "merged" else {
    raise @domain.BadRequest(message="merge request is already merged")
  }
  guard mr.job_status != "pending" && mr.job_status != "running" else {
    raise @domain.BadRequest(message="a merge is already in progress")
  }
}

///|
pub fn edit_merge_request(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  action : String,
  title : String,
  description : String,
  expected? : Int64,
) -> Unit raise {
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
  guard expected.unwrap_or(mr.edit_version) == mr.edit_version else {
    raise @domain.BadRequest(
      message="merge request changed; reload before saving",
    )
  }
  require_mutable_merge(mr)
  guard actor.id == mr.author_id ||
    @identity.can_manage_team(pool, actor, scope.team_id) else {
    raise @domain.Forbidden(
      message="only the author or a team administrator may edit this merge request",
    )
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      match action {
        "edit" => {
          let title = title.trim().to_owned()
          guard !title.is_empty() &&
            title.length() <= 200 &&
            description.length() <= 20000 else {
            raise @domain.BadRequest(
              message="invalid title or description length",
            )
          }
          let _ = tx.execute(
            "UPDATE merge_request SET title = ?, description = ?, updated_at = datetime('now') WHERE id = ?",
            params=[title, description, mr.id],
          )
          @attachments.replace_references(
            tx,
            scope.id,
            actor.id,
            MergeRequest(mr.id),
            description,
          )
        }
        "draft" | "ready" => {
          guard mr.status == "open" && mr.draft == (action == "ready") else {
            raise @domain.BadRequest(
              message="merge request is not in the expected draft state",
            )
          }
          let _ = tx.execute(
            "UPDATE merge_request SET draft = ?, updated_at = datetime('now') WHERE id = ?",
            params=[action == "draft", mr.id],
          )
        }
        "close" | "reopen" => {
          guard mr.status == (if action == "close" { "open" } else { "closed" }) else {
            raise @domain.BadRequest(
              message="merge request is not in the expected open or closed state",
            )
          }
          if action == "reopen" {
            guard tx.query_opt(
                "SELECT id FROM merge_request WHERE repository_id = ? AND source_branch = ? AND target_branch = ? AND status = 'open' AND id <> ?",
                params=[scope.id, mr.source, mr.target, mr.id],
              )
              is None else {
              raise @domain.BadRequest(
                message="another open merge request already uses these branches",
              )
            }
          }
          let _ = tx.execute(
            "UPDATE merge_request SET status = ?, updated_at = datetime('now') WHERE id = ?",
            params=[if action == "close" { "closed" } else { "open" }, mr.id],
          )
          // Reopening or changing draft status must not reactivate old approvals.
          let _ = tx.execute(
            "DELETE FROM merge_review WHERE merge_request_id = ? AND decision = 'approved'",
            params=[mr.id],
          )
        }
        _ => raise @domain.BadRequest(message="invalid merge request action")
      }
      let _ = tx.execute(
        "UPDATE merge_request SET edit_version = edit_version + 1 WHERE id = ?",
        params=[mr.id],
      )
      if action == "draft" || action == "ready" {
        let _ = tx.execute(
          "DELETE FROM merge_review WHERE merge_request_id = ? AND decision = 'approved'",
          params=[mr.id],
        )
      }
      if ["draft", "ready", "close", "reopen"].contains(action) {
        ignore(
          tx.execute(
            "UPDATE merge_request SET check_generation = check_generation + 1, checks_poll_after = 0 WHERE id = ?",
            params=[mr.id],
          ),
        )
      }
      if action == "reopen" {
        ignore(
          tx.execute(
            "UPDATE merge_request SET workflow_event = 'reopened', workflow_event_pending = 1 WHERE id = ?",
            params=[mr.id],
          ),
        )
      }
      merge_activity(tx, mr, actor.id, action)
    })
  })
}

///|
pub fn submit_merge_review(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  version : Int64,
  decision : String,
  body : String,
) -> Unit raise {
  let allowed = pool.with_client(client => {
    client.query_opt(
      "SELECT u.id FROM \"user\" AS u JOIN repository AS r ON r.id = ? LEFT JOIN team_member AS tm ON tm.team_id = r.team_id AND tm.user_id = u.id WHERE u.id = ? AND u.status = 'active' AND (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin', 'member'))",
      params=[mr.repository_id, actor.id],
    )
    is Some(_)
  })
  guard allowed else {
    raise @domain.Forbidden(message="repository contributor access required")
  }
  guard body.length() <= 20000 else {
    raise @domain.BadRequest(message="comment is too long")
  }
  guard version == mr.version else {
    raise @domain.BadRequest(
      message="the branches changed; reload and review the current version",
    )
  }
  if decision == "comment" {
    guard !body.trim().is_empty() else {
      raise @domain.BadRequest(message="comment cannot be empty")
    }
  } else {
    require_mutable_merge(mr)
    guard mr.status == "open" && !mr.draft else {
      raise @domain.BadRequest(
        message="only open, ready merge requests can be reviewed",
      )
    }
    guard actor.id != mr.author_id else {
      raise @domain.Forbidden(
        message="authors cannot approve or review their own merge requests",
      )
    }
    guard decision == "approved" ||
      decision == "changes_requested" ||
      decision == "withdrawn" else {
      raise @domain.BadRequest(message="invalid review decision")
    }
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      if decision != "comment" {
        let _ = tx.execute(
          "INSERT INTO merge_review (merge_request_id, user_id, version, decision) VALUES (?, ?, ?, ?) ON CONFLICT (merge_request_id, user_id) DO UPDATE SET version = excluded.version, decision = excluded.decision",
          params=[mr.id, actor.id, version, decision],
        )
      }
      merge_activity(tx, mr, actor.id, decision, body~)
    })
  })
}

///|
pub fn merge_review_counts(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  mr : MergeRequest,
) -> (Int64, Int64) raise {
  pool.with_client(client => {
    let rows = client.query_all(
      "SELECT r.decision FROM merge_review AS r JOIN \"user\" AS u ON u.id = r.user_id LEFT JOIN team_member AS tm ON tm.user_id = u.id AND tm.team_id = ? WHERE r.merge_request_id = ? AND r.version = ? AND u.id <> ? AND u.status = 'active' AND (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin', 'member'))",
      params=[scope.team_id, mr.id, mr.version, mr.author_id],
    )
    let mut approved = 0L
    let mut blocked = 0L
    for row in rows {
      let decision : String = row.get_name("decision")
      if decision == "approved" {
        approved += 1L
      }
      if decision == "changes_requested" {
        blocked += 1L
      }
    }
    (approved, blocked)
  })
}

///|
pub fn required_merge_approvals(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  branch : String,
) -> Int64 raise {
  pool.with_client(client => {
    match
      client.query_opt(
        "SELECT required_approvals FROM branch_rule WHERE repository_id = ? AND branch = ?",
        params=[scope.id, branch],
      ) {
      Some(row) => row.get_name("required_approvals")
      None => 0L
    }
  })
}

///|
pub fn merge_blocker(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  mr : MergeRequest,
  revision : MergeRevision,
) -> String raise {
  if mr.status != "open" {
    return "Merge request is \{mr.status}."
  }
  if mr.draft {
    return "Draft: mark ready before merging."
  }
  if !revision.block_reason.is_empty() {
    return revision.block_reason
  }
  let (approved, blocked) = merge_review_counts(pool, scope, mr)
  if blocked > 0L {
    return "Changes have been requested for this version."
  }
  let required = required_merge_approvals(pool, scope, mr.target)
  if approved < required {
    return "Waiting for \{required} approval from another team member."
  }
  merge_checks_blocker(pool, scope, mr)
}

///|
pub fn enqueue_merge(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  version : Int64,
) -> Unit raise {
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
  require_mutable_merge(mr)
  guard @identity.can_manage_team(pool, actor, scope.team_id) else {
    raise @domain.Forbidden(message="team owner or admin required to merge")
  }
  guard version == mr.version else {
    raise @domain.BadRequest(
      message="branches changed; review the current version before merging",
    )
  }
  let blocked = merge_blocker(pool, scope, mr, merge_revision(pool, mr))
  guard blocked.is_empty() else { raise @domain.BadRequest(message=blocked) }
  pool.with_client(client => {
    client.with_transaction(tx => {
      let _ = tx.execute(
        "INSERT INTO merge_job (merge_request_id, actor_id, version) VALUES (?, ?, ?) ON CONFLICT (merge_request_id) DO UPDATE SET actor_id = excluded.actor_id, version = excluded.version, status = 'pending', result_sha = NULL, last_error = NULL, updated_at = datetime('now')",
        params=[mr.id, actor.id, mr.version],
      )
      merge_activity(tx, mr, actor.id, "merge_queued")
    })
  })
}
