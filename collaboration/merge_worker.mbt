///|
fn finish_merge(
  pool : @database.Database,
  mr : MergeRequest,
  actor_id : Int64,
  sha : String,
) -> Unit raise {
  pool.with_client(client => {
    client.with_transaction(tx => {
      let changed = tx.execute(
        "UPDATE merge_request SET status = 'merged', merged_sha = ?, updated_at = datetime('now') WHERE id = ? AND status <> 'merged'",
        params=[sha, mr.id],
      )
      let _ = tx.execute(
        "UPDATE merge_job SET status = 'succeeded', last_error = NULL, updated_at = datetime('now') WHERE merge_request_id = ?",
        params=[mr.id],
      )
      if changed == 1 {
        @repository.record_merged_ref(
          tx,
          mr.repository_id,
          actor_id,
          mr.id,
          mr.target,
          sha,
        )
        merge_activity(tx, mr, actor_id, "merged", body=sha)
      }
    })
  })
}

///|
async fn recover_merge(
  pool : @database.Database,
  git_dir : String,
  mr : MergeRequest,
  actor_id : Int64,
  result : String,
) -> Bool {
  let (code, output) = @gitops.merge_git_command(git_dir, [
    "rev-parse",
    "--verify",
    "--quiet",
    "refs/moonhub/merges/\{mr.id}",
  ])
  if code == 1 {
    return false
  }
  guard code == 0 else {
    raise @domain.BadRequest(message="cannot inspect merge recovery receipt")
  }
  if !@gitops.valid_commit_sha(result) || output.trim() != result {
    fail_merge(
      pool, mr, actor_id, "merge recovery marker does not match the recorded commit; operator inspection required",
    )
    return true
  }
  finish_merge(pool, mr, actor_id, result)
  true
}

///|
async fn execute_merge(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  git_dir : String,
  mr : MergeRequest,
  actor_id : Int64,
  version : Int64,
) -> Unit {
  let actor_name : String = pool.with_client(client => {
    let row = client.query_opt(
      "SELECT name_key FROM \"user\" WHERE id = ? AND status = 'active'",
      params=[actor_id],
    )
    guard row is Some(row) else {
      raise @domain.Forbidden(message="the merging user is no longer active")
    }
    row.get_name("name_key")
  })
  let actor = @identity.active_user_by_name(pool, actor_name)
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
  guard @identity.can_manage_team(pool, actor, scope.team_id) else {
    raise @domain.Forbidden(message="merge permission was revoked")
  }
  guard version == mr.version else {
    raise @domain.BadRequest(message="merge request version changed")
  }
  let revision = merge_revision(pool, mr)
  let source_sha = @gitops.branch_sha(git_dir, mr.source)
  let target_sha = @gitops.branch_sha(git_dir, mr.target)
  guard source_sha == revision.source_sha && target_sha == revision.target_sha else {
    raise @domain.BadRequest(
      message="branches changed; reload and review the new version",
    )
  }
  let blocker = merge_blocker(pool, scope, mr, revision)
  guard blocker.is_empty() else { raise @domain.BadRequest(message=blocker) }
  let tree = @gitops.merged_tree(git_dir, revision)
  guard tree == revision.merge_tree else {
    raise @domain.BadRequest(
      message="merge result changed; refresh the comparison before merging",
    )
  }
  let (code, output) = @gitops.merge_git_command(
    git_dir,
    ["commit-tree", tree, "-p", target_sha, "-p", source_sha],
    input="Merge request !\{mr.number}: \{mr.title}\n\nMerged by \{actor.name_key}.\n",
  )
  let result = output.trim().to_owned()
  guard code == 0 && @gitops.valid_commit_sha(result) else {
    raise @domain.BadRequest(message="could not create merge commit")
  }
  // The intent is durable before Git changes. The hidden marker is committed
  // atomically with the target, so recovery survives later pushes to that target.
  pool.with_client(client => {
    let _ = client.execute(
      "UPDATE merge_job SET result_sha = ?, updated_at = datetime('now') WHERE merge_request_id = ?",
      params=[result, mr.id],
    )
  })
  let actor = @identity.active_user_by_name(pool, actor_name)
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
  guard @identity.can_manage_team(pool, actor, scope.team_id) else {
    raise @domain.Forbidden(message="merge permission was revoked")
  }
  let blocker = merge_blocker(pool, scope, mr, revision)
  guard blocker.is_empty() else { raise @domain.BadRequest(message=blocker) }
  ignore(
    @gitops.merge_git(
      git_dir,
      ["update-ref", "--no-deref", "--stdin"],
      input="start\nverify refs/heads/\{mr.source} \{source_sha}\nupdate refs/heads/\{mr.target} \{result} \{target_sha}\ncreate refs/moonhub/merges/\{mr.id} \{result}\nprepare\ncommit\n",
    ),
  )
  finish_merge(pool, mr, actor_id, result)
}

///|
pub async fn run_next_merge_job(
  pool : @database.Database,
  root : String,
) -> Bool {
  let row = pool.with_client(client => {
    client.query_opt(
      "SELECT j.merge_request_id, j.actor_id, j.version, r.id AS repository_id, r.team_id, r.name, t.name_key AS owner, m.number FROM merge_job AS j JOIN merge_request AS m ON m.id = j.merge_request_id JOIN repository AS r ON r.id = m.repository_id JOIN team AS t ON t.id = r.team_id WHERE j.status IN ('pending', 'running') ORDER BY j.updated_at, j.merge_request_id LIMIT 1",
    )
  })
  guard row is Some(row) else { return false }
  let scope : @repository.RepositoryScope = {
    id: row.get_name("repository_id"),
    team_id: row.get_name("team_id"),
    repo: { owner: row.get_name("owner"), name: row.get_name("name"), },
  }
  let git_dir = @repository.resolve_repository_dir(root, scope.repo)
  let lock = @gitops.repository_write_lock(git_dir)
  defer lock.close()
  @repository.recover_ref_events_locked(pool, scope, git_dir)
  let mr = require_merge_request(pool, scope, row.get_name("number"))
  if mr.job_status != "pending" && mr.job_status != "running" {
    return false
  }
  let job = pool.with_client(client => {
    client
    .query_opt(
      "SELECT actor_id, version, COALESCE(result_sha, '') AS result_sha FROM merge_job WHERE merge_request_id = ?",
      params=[mr.id],
    )
    .unwrap()
  })
  let actor_id : Int64 = job.get_name("actor_id")
  let version : Int64 = job.get_name("version")
  let previous : String = job.get_name("result_sha")
  if recover_merge(pool, git_dir, mr, actor_id, previous) {
    return true
  }
  pool.with_client(client => {
    let _ = client.execute(
      "UPDATE merge_job SET status = 'running', updated_at = datetime('now') WHERE merge_request_id = ?",
      params=[mr.id],
    )
  })
  execute_merge(pool, scope, git_dir, mr, actor_id, version) catch {
    err if @async.is_being_cancelled() => {
      @async.pause()
      raise err
    }
    err => {
      println("merge request \{mr.id} failed: \{err}")
      let result : String = pool.with_client(client => {
        client
        .query_opt(
          "SELECT COALESCE(result_sha, '') AS result_sha FROM merge_job WHERE merge_request_id = ?",
          params=[mr.id],
        )
        .unwrap()
        .get_name("result_sha")
      })
      if !recover_merge(pool, git_dir, mr, actor_id, result) {
        let message = match err {
          @domain.BadRequest(message~)
          | @gitops.Failure(message~)
          | @domain.NotFound(message~)
          | @domain.Forbidden(message~)
          | @domain.Unauthorized(message~) => message
          @gitops.InternalFailure(_) => @domain.merge_error_message
          _ => "merge failed; retry after inspecting the branches"
        }
        fail_merge(pool, mr, actor_id, message)
      }
    }
  }
  true
}

///|
fn fail_merge(
  pool : @database.Database,
  mr : MergeRequest,
  actor_id : Int64,
  message : String,
) -> Unit raise {
  pool.with_client(client => {
    client.with_transaction(tx => {
      let changed = tx.execute(
        "UPDATE merge_job SET status = 'failed', last_error = ?, updated_at = datetime('now') WHERE merge_request_id = ? AND status IN ('pending', 'running')",
        params=[message, mr.id],
      )
      if changed == 1 {
        merge_activity(tx, mr, actor_id, "merge_failed", body=message)
      }
    })
  })
}

///|
pub fn start_merge_worker(
  pool : @database.Database,
  root : String,
  group : @async.TaskGroup[Unit],
) -> Unit {
  group.spawn_bg(no_wait=true, () => {
    for ;; {
      let processed = run_next_merge_job(pool, root) catch {
        err => {
          println("merge worker error: \{err}")
          false
        }
      }
      if !processed {
        @async.sleep(1000)
      }
    }
  })
}
