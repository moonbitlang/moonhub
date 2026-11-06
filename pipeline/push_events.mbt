///|
pub async fn run_next_push_event(
  pool : @database.Database,
  root : String,
) -> Bool {
  let row = pool.with_client(client => {
    client.query_opt(
      "SELECT e.id, e.repository_id, r.team_id, r.name, t.name_key AS owner FROM repository_ref_event e JOIN repository r ON r.id = e.repository_id JOIN team t ON t.id = r.team_id WHERE e.state IN ('prepared', 'committed', 'ready') AND e.retry_after <= CAST(strftime('%s', 'now') AS INTEGER) ORDER BY e.id LIMIT 1",
    )
  })
  guard row is Some(row) else { return false }
  let id : Int64 = row.get_name("id")
  // A broken repository or temporarily busy writer must not starve other repos.
  errdefer (pool.with_client(client => {
    ignore(
      client.execute(
        "UPDATE repository_ref_event SET retry_after = CAST(strftime('%s', 'now') AS INTEGER) + 30, last_error = 'Trigger processing interrupted; retrying.' WHERE id = ? AND state IN ('prepared', 'committed', 'ready')",
        params=[id],
      ),
    )
  }) catch {
    _ => ()
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
  let row = pool.with_client(client => {
    client.query_one(
      "SELECT e.*, u.name_key AS actor_name, r.pipeline_push_enabled FROM repository_ref_event e JOIN \"user\" u ON u.id = e.actor_id JOIN repository r ON r.id = e.repository_id WHERE e.id = ?",
      params=[id],
    )
  })
  guard (row.get_name("state") : String) == "ready" else { return true }
  let mut error = ""
  if (row.get_name("pipeline_push_enabled") : Bool) {
    try {
      let actor = @identity.active_user_by_name(
        pool,
        row.get_name("actor_name"),
      )
      ignore(require_run_author(pool, actor, scope.repo))
      let sha : String = row.get_name("new_sha")
      let reference : String = row.get_name("reference")
      let branch = reference.strip_prefix("refs/heads/").unwrap().to_owned()
      let output = @gitops.merge_git(git_dir, [
        "ls-tree", sha, ".github/workflows/",
      ])
      let paths : Array[String] = []
      for line in @domain.split_lines(output) {
        guard line.split_once("\t") is Some((_, path)) else { continue }
        let path = path.to_owned()
        if path.has_suffix(".yml") || path.has_suffix(".yaml") {
          paths.push(path)
        }
      }
      guard paths.length() <= 64 else {
        raise @domain.BadRequest(
          message="push contains more than 64 workflow files",
        )
      }
      let old : String = row.get_name("old_sha")
      let old = if old.is_empty() {
        let (code, value) = @gitops.merge_git_command(git_dir, [
          "rev-parse",
          "--verify",
          "--quiet",
          sha + "^1",
        ])
        if code == 0 {
          value.trim().to_owned()
        } else {
          ""
        }
      } else {
        old
      }
      let mut changes : Array[String]? = None
      let mut changes_loaded = false
      for path in paths {
        let exists = pool.with_client(client => {
          client.query_opt(
            "SELECT id FROM pipeline_run WHERE trigger_event_id = ? AND workflow_path = ?",
            params=[id, path],
          )
          is Some(_)
        })
        if exists {
          continue
        }
        try {
          validate_workflow_path(path)
          let source = read_workflow_source(git_dir, sha, path)
          let trigger = @workflow.triggers(source)
          if !trigger.matches_push(branch) {
            continue
          }
          if !changes_loaded &&
            (
              !trigger.push_filters.paths.is_empty() ||
              !trigger.push_filters.paths_ignore.is_empty()
            ) {
            changes = changed_paths(git_dir, old, sha)
            changes_loaded = true
          }
          if !trigger.matches_push(branch, paths=changes) {
            continue
          }
          let context : @workflow.RunContext = {
            repository: scope.repo.owner + "/" + scope.repo.name,
            sha,
            event_name: "push",
            head_ref: "",
            base_ref: "",
            inputs: Map([]),
            variables: Map([]),
          }
          let definition = @workflow.resolve_context(
            @workflow.parse(source),
            context,
          )
          let pin = "refs/moonhub/pipelines/push-" +
            id.to_string() +
            "/" +
            @identity.hash_token(path)
          ignore(
            @gitops.merge_git(git_dir, ["update-ref", "--no-deref", pin, sha]),
          )
          ignore(require_run_author(pool, actor, scope.repo))
          pool.with_client(client => {
            client.with_transaction(tx => {
              ignore(
                insert_run_snapshot(
                  tx,
                  scope.id,
                  actor.id,
                  path,
                  if definition.name.is_empty() {
                    path
                  } else {
                    definition.name
                  },
                  branch,
                  sha,
                  pin,
                  source,
                  definition,
                  context=Some(context),
                  event_id=id,
                ),
              )
            })
          })
        } catch {
          @workflow.InvalidWorkflow(message) | @domain.BadRequest(message~) =>
            if error.is_empty() {
              error = path + ": " + message
            }
          err => raise err
        }
      }
    } catch {
      @domain.BadRequest(message~)
      | @domain.Unauthorized(message~)
      | @domain.Forbidden(message~)
      | @domain.NotFound(message~) => error = message
      err => raise err
    }
  } else {
    error = "Automatic push workflows are disabled."
  }
  pool.with_client(client => {
    ignore(
      client.execute(
        "UPDATE repository_ref_event SET state = 'processed', last_error = ? WHERE id = ?",
        params=[error, id],
      ),
    )
  })
  true
}

///|
pub fn start_push_worker(
  pool : @database.Database,
  root : String,
  group : @async.TaskGroup[Unit],
) -> Unit {
  group.spawn_bg(no_wait=true, () => {
    for ;; {
      let processed = run_next_push_event(pool, root) catch {
        _ => {
          println("pipeline push event failed; will retry")
          false
        }
      }
      if !processed {
        @async.sleep(1000)
      }
    }
  })
}
