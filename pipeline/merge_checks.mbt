///|
fn cancel_check_run(tx : @database.DbTransaction, run_id : Int64) -> Unit raise {
  ignore(
    tx.execute(
      "UPDATE pipeline_run SET cancel_requested = 1 WHERE id = ? AND status <> 'completed'",
      params=[run_id],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job SET status = 'completed', conclusion = 'cancelled' WHERE run_id = ? AND status IN ('queued', 'waiting')",
      params=[run_id],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job_attempt SET cancel_at_ms = COALESCE(cancel_at_ms, CAST(strftime('%s', 'now') AS INTEGER) * 1000) WHERE status <> 'completed' AND job_id IN (SELECT id FROM pipeline_job WHERE run_id = ?)",
      params=[run_id],
    ),
  )
  finalize_run(tx, run_id)
}

///|
fn cancel_obsolete_merge_checks(
  pool : @database.Database,
  mr : @collaboration.MergeRequest,
) -> Unit raise {
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        let obsolete = tx.query_all(
          "SELECT c.id FROM merge_check c JOIN merge_request m ON m.id = c.merge_request_id WHERE m.id = ? AND (m.status <> 'open' OR m.draft = 1 OR c.version <> m.current_version OR c.generation <> m.check_generation OR (c.automatic = 0 AND NOT EXISTS (SELECT 1 FROM branch_required_check b WHERE b.repository_id = m.repository_id AND b.branch = m.target_branch AND b.workflow_path = c.workflow_path))) AND c.state IN ('pending', 'awaiting_approval', 'queued', 'running', 'error')",
          params=[mr.id],
        )
        for row in obsolete {
          let id : Int64 = row.get_name("id")
          for
            run in tx.query_all(
              "SELECT id FROM pipeline_run WHERE merge_check_id = ? AND status <> 'completed'",
              params=[id],
            ) {
            cancel_check_run(tx, run.get_name("id"))
          }
          ignore(
            tx.execute(
              "UPDATE merge_check SET state = 'completed', conclusion = 'cancelled' WHERE id = ? AND state IN ('pending', 'awaiting_approval', 'error')",
              params=[id],
            ),
          )
        }
      },
      immediate=true,
    )
  })
}

///|
// Discovery and execution share one candidate pinned under the repository lock.
async fn merge_check_snapshot(
  git_dir : String,
  mr : @collaboration.MergeRequest,
  revision : @gitops.Revision,
) -> String {
  guard revision.block_reason.is_empty() else {
    raise @domain.BadRequest(
      message="Resolve merge conflicts before running checks.",
    )
  }
  let pin = "refs/moonhub/mr/\{mr.id}/\{mr.version}/candidate"
  let (code, saved) = @gitops.merge_git_command(git_dir, [
    "rev-parse", "--verify", "--quiet", pin,
  ])
  if code == 0 {
    let sha = saved.trim().to_owned()
    guard @gitops.valid_commit_sha(sha) else {
      raise @domain.BadRequest(
        message="Could not read the merge check snapshot.",
      )
    }
    return sha
  }
  let tree = @gitops.merged_tree(git_dir, revision)
  guard tree == revision.merge_tree else {
    raise @domain.BadRequest(
      message="Merge comparison changed; refresh the merge request.",
    )
  }
  let sha = @gitops.merge_git(
      git_dir,
      [
        "commit-tree",
        tree,
        "-p",
        revision.target_sha,
        "-p",
        revision.source_sha,
      ],
      input="Check merge request !\{mr.number}, version \{mr.version}\n",
    )
    .trim()
    .to_owned()
  guard @gitops.valid_commit_sha(sha) else {
    raise @domain.BadRequest(
      message="Could not create the merge check snapshot.",
    )
  }
  ignore(
    @gitops.merge_git(
      git_dir,
      ["update-ref", "--no-deref", "--stdin"],
      input="create \{pin} \{sha}\n",
    ),
  )
  sha
}

///|
async fn create_merge_check_run(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  git_dir : String,
  mr : @collaboration.MergeRequest,
  sha : String,
  check_id : Int64,
  actor_name : String,
  workflow_path : String,
) -> Unit {
  let actor = @identity.active_user_by_name(pool, actor_name)
  ignore(require_run_author(pool, actor, scope.repo))
  validate_workflow_path(workflow_path)
  let source = read_workflow_source(git_dir, sha, workflow_path)
  let definition = @workflow.parse(source)
  let context : @workflow.RunContext = {
    repository: scope.repo.owner + "/" + scope.repo.name,
    sha,
    event_name: "pull_request",
    head_ref: mr.source,
    base_ref: mr.target,
    inputs: Map([]),
  }
  let definition = @workflow.resolve_context(definition, context)
  let pin = "refs/moonhub/pipelines/mr-" + check_id.to_string()
  ignore(@gitops.merge_git(git_dir, ["update-ref", "--no-deref", pin, sha]))
  ignore(require_run_author(pool, actor, scope.repo))
  pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.query_opt(
          "SELECT c.id FROM merge_check c JOIN merge_request m ON m.id = c.merge_request_id WHERE c.id = ? AND c.state = 'pending' AND c.run_number IS NULL AND m.status = 'open' AND m.draft = 0 AND c.version = m.current_version AND c.generation = m.check_generation",
          params=[check_id],
        )
        is Some(_) else {
        return
      }
      ignore(
        insert_run_snapshot(
          tx,
          scope.id,
          actor.id,
          workflow_path,
          if definition.name.is_empty() {
            workflow_path
          } else {
            definition.name
          },
          mr.source,
          sha,
          pin,
          source,
          definition,
          context=Some(context),
          merge_check_id=check_id,
        ),
      )
    })
  })
}

///|
pub async fn run_next_merge_check(
  pool : @database.Database,
  root : String,
) -> Bool {
  let row = pool.with_client(client => {
    client.query_opt(
      "SELECT m.id, m.number, r.id AS repository_id, r.team_id, r.name, t.name_key AS owner FROM merge_request m JOIN repository r ON r.id = m.repository_id JOIN team t ON t.id = r.team_id WHERE r.ready = 1 AND m.checks_poll_after <= CAST(strftime('%s', 'now') AS INTEGER) AND ((m.status = 'open' AND m.draft = 0) OR EXISTS (SELECT 1 FROM merge_check c WHERE c.merge_request_id = m.id AND c.state IN ('pending', 'queued', 'running', 'awaiting_approval'))) ORDER BY m.checks_poll_after, m.id LIMIT 1",
    )
  })
  guard row is Some(row) else { return false }
  let id : Int64 = row.get_name("id")
  // Persist the polling cursor before awaiting Git: a broken repo must not
  // starve other requests, including after a process restart.
  pool.with_client(client => {
    ignore(
      client.execute(
        "UPDATE merge_request SET checks_poll_after = CAST(strftime('%s', 'now') AS INTEGER) + 5 WHERE id = ?",
        params=[id],
      ),
    )
  })
  let scope : @repository.RepositoryScope = {
    id: row.get_name("repository_id"),
    team_id: row.get_name("team_id"),
    repo: { owner: row.get_name("owner"), name: row.get_name("name"), },
  }
  let git_dir = @repository.resolve_repository_dir(root, scope.repo)
  let lock = @gitops.repository_write_lock(git_dir)
  defer lock.close()
  @repository.recover_ref_events_locked(pool, scope, git_dir)
  let mut mr = @collaboration.require_merge_request(
    pool,
    scope,
    row.get_name("number"),
  )
  try {
    mr = @collaboration.refresh_merge_request(pool, scope, git_dir, mr)
  } catch {
    @domain.BadRequest(_) | @gitops.Failure(_) => {
      pool.with_client(client => {
        client.with_transaction(tx => {
          for
            run in tx.query_all(
              "SELECT p.id FROM pipeline_run p JOIN merge_check c ON c.id = p.merge_check_id WHERE c.merge_request_id = ? AND p.status <> 'completed'",
              params=[id],
            ) {
            cancel_check_run(tx, run.get_name("id"))
          }
          ignore(
            tx.execute(
              "UPDATE merge_check SET state = 'error', last_error = 'Branches unavailable; restore the branches and approve checks again.' WHERE merge_request_id = ? AND state IN ('pending', 'awaiting_approval')",
              params=[id],
            ),
          )
        })
      })
      return true
    }
    err => raise err
  }
  cancel_obsolete_merge_checks(pool, mr)
  if mr.job_status == "pending" || mr.job_status == "running" {
    return true
  }
  if mr.status != "open" || mr.draft {
    return true
  }
  let workflows : Array[String] = []
  let revision = @collaboration.merge_revision(pool, mr)
  let (sha, snapshot_error) = try
    merge_check_snapshot(git_dir, mr, revision)
  catch {
    @domain.BadRequest(message~) | @gitops.Failure(message~) => ("", message)
    err => raise err
  } noraise {
    sha => (sha, "")
  }
  if snapshot_error.is_empty() {
    let event : String = pool.with_client(client => {
      client
      .query_one("SELECT workflow_event FROM merge_request WHERE id = ?", params=[
        mr.id,
      ])
      .get_name("workflow_event")
    })
    let output = @gitops.merge_git(git_dir, [
      "ls-tree", sha, ".github/workflows/",
    ])
    let paths = @domain.split_lines(output)
    guard paths.length() <= 64 else {
      raise @domain.BadRequest(
        message="candidate contains more than 64 workflow files",
      )
    }
    let mut changes : Array[String]? = None
    let mut changes_loaded = false
    for line in paths {
      guard line.split_once("\t") is Some((_, entry)) else { continue }
      let path = entry.to_owned()
      guard path.has_suffix(".yml") || path.has_suffix(".yaml") else {
        continue
      }
      try {
        validate_workflow_path(path)
        let source = read_workflow_source(git_dir, sha, path)
        let trigger = @workflow.triggers(source)
        if !trigger.matches_pull_request(event, branch=mr.target) {
          continue
        }
        if !changes_loaded &&
          (
            !trigger.pull_request_filters.paths.is_empty() ||
            !trigger.pull_request_filters.paths_ignore.is_empty()
          ) {
          changes = changed_paths(
            git_dir,
            revision.base_sha,
            revision.source_sha,
          )
          changes_loaded = true
        }
        if trigger.matches_pull_request(event, branch=mr.target, paths=changes) {
          workflows.push(path)
        }
      } catch {
        // Show invalid definitions as preparation failures on this MR instead
        // of silently losing diagnostics or starving the remaining workflows.
        @workflow.InvalidWorkflow(_)
        | @domain.BadRequest(_)
        | @gitops.Failure(_) => workflows.push(path)
        err => raise err
      }
    }
  }
  @collaboration.prepare_merge_checks(pool, scope, mr, workflows~)
  let checks = pool.with_client(client => {
    client.query_all(
      "SELECT c.id, c.workflow_path, u.name_key FROM merge_check c JOIN merge_request m ON m.id = c.merge_request_id JOIN \"user\" u ON u.id = c.requested_by_user_id WHERE m.id = ? AND m.status = 'open' AND m.draft = 0 AND c.version = m.current_version AND c.generation = m.check_generation AND c.state = 'pending' AND c.retry_after <= CAST(strftime('%s', 'now') AS INTEGER) ORDER BY c.id LIMIT 16",
      params=[mr.id],
    )
  })
  for check in checks {
    let check_id : Int64 = check.get_name("id")
    try {
      guard snapshot_error.is_empty() else {
        raise @domain.BadRequest(message=snapshot_error)
      }
      create_merge_check_run(
        pool,
        scope,
        git_dir,
        mr,
        sha,
        check_id,
        check.get_name("name_key"),
        check.get_name("workflow_path"),
      )
    } catch {
      err => {
        let message = match err {
          @workflow.InvalidWorkflow(message)
          | @domain.BadRequest(message~)
          | @gitops.Failure(message~) => message
          @domain.Forbidden(_)
          | @domain.Unauthorized(_)
          | @domain.NotFound(_) =>
            "Execution permission was revoked; a repository manager must approve checks."
          _ => "Could not prepare checks; a repository manager can retry."
        }
        pool.with_client(client => {
          ignore(
            client.execute(
              "UPDATE merge_check SET state = 'error', last_error = ? WHERE id = ? AND state = 'pending'",
              params=[message, check_id],
            ),
          )
        })
      }
    }
  }
  true
}

///|
async fn validate_merge_check_rerun(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  git_dir : String,
  check_id : Int64,
  previous_number : Int64,
) -> Unit {
  let row = pool.with_client(client => {
    client.query_opt(
      "SELECT m.number FROM merge_check c JOIN merge_request m ON m.id = c.merge_request_id WHERE c.id = ? AND m.repository_id = ? AND m.status = 'open' AND m.draft = 0 AND c.version = m.current_version AND c.generation = m.check_generation AND c.run_number = ? AND m.id NOT IN (SELECT merge_request_id FROM merge_job WHERE status IN ('pending', 'running')) AND (c.automatic = 1 OR EXISTS (SELECT 1 FROM branch_required_check b WHERE b.repository_id = m.repository_id AND b.branch = m.target_branch AND b.workflow_path = c.workflow_path))",
      params=[check_id, scope.id, previous_number],
    )
  })
  guard row is Some(row) else {
    raise @domain.BadRequest(
      message="Only the latest check of an open, ready merge request can be rerun.",
    )
  }
  let mr = @collaboration.require_merge_request(
    pool,
    scope,
    row.get_name("number"),
  )
  let revision = @collaboration.merge_revision(pool, mr)
  guard @gitops.branch_sha(git_dir, mr.source) == revision.source_sha &&
    @gitops.branch_sha(git_dir, mr.target) == revision.target_sha else {
    raise @domain.BadRequest(
      message="Branches changed; run checks for the new merge request version.",
    )
  }
}

///|
pub fn start_merge_checks_worker(
  pool : @database.Database,
  root : String,
  group : @async.TaskGroup[Unit],
) -> Unit {
  group.spawn_bg(no_wait=true, () => {
    for ;; {
      let processed = run_next_merge_check(pool, root) catch {
        _ => {
          println("merge checks worker failed; retrying")
          false
        }
      }
      if !processed {
        @async.sleep(1000)
      }
    }
  })
}
