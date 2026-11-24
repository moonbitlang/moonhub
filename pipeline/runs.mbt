///|
priv suberror SnapshotError {
  SnapshotError(String)
}

///|
async fn read_workflow_source(
  git_dir : String,
  sha : String,
  path : String,
) -> String {
  let (code, entry) = @gitops.merge_git_command(
    git_dir,
    ["ls-tree", sha, "--", path],
    limit=4096,
  )
  guard code == 0 else {
    raise SnapshotError("could not read workflow tree entry")
  }
  let (meta, name) = entry
    .trim_end(chars="\n")
    .split_once("\t")
    .unwrap_or(("", ""))
  let parts = meta.split(" ").collect()
  guard name == path &&
    parts.length() == 3 &&
    (parts[0] == "100644" || parts[0] == "100755") &&
    parts[1] == "blob" &&
    @gitops.valid_commit_sha(parts[2].to_owned()) else {
    raise @domain.BadRequest(
      message="workflow is missing or is not a regular file",
    )
  }
  let (code, source) = @gitops.merge_git_command(
    git_dir,
    ["cat-file", "blob", parts[2].to_owned()],
    limit=@workflow.max_source_bytes,
    strict_utf8=true,
  )
  guard code == 0 else { raise SnapshotError("could not read workflow blob") }
  source
}

///|
pub async fn create_run(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  branch : String,
  workflow_path : String,
  inputs~ : Map[String, Json] = Map([]),
  jobs~ : Array[String] = [],
) -> @runtime.Run {
  create_run_event(
    pool,
    root,
    actor,
    @runtime.require_run_author(pool, actor, repo),
    branch,
    workflow_path,
    inputs~,
    jobs~,
  )
}

///|
async fn create_run_event(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  branch : String,
  workflow_path : String,
  inputs~ : Map[String, Json] = Map([]),
  jobs~ : Array[String] = [],
  scheduled_minute~ : Int64 = -1L,
) -> @runtime.Run {
  let repo = scope.repo
  @runtime.validate_workflow_path(workflow_path)
  @repository.with_repository_write(pool, root, actor, scope, (scope, git_dir) => {
    ignore(@runtime.require_run_author(pool, actor, repo))
    if scheduled_minute >= 0L {
      let previous = pool.with_client(c => {
        let config = c.query_opt(
          "SELECT actor_id FROM pipeline_schedule_config WHERE repository_id=? AND enabled=1",
          params=[scope.id],
        )
        guard config is Some(config) &&
          (config.get_name("actor_id") : Int64) == actor.id else {
          raise @domain.Forbidden(message="scheduled execution is disabled")
        }
        c.query_opt(
          "SELECT r.* FROM pipeline_schedule_tick t JOIN pipeline_run r ON r.id=t.run_id WHERE t.repository_id=? AND t.workflow_path=? AND t.minute=?",
          params=[scope.id, workflow_path, scheduled_minute],
        )
      })
      if previous is Some(previous) {
        return @runtime.get_run(pool, actor, repo, previous.get_name("number"))
      }
    }
    let sha = @gitops.branch_sha(git_dir, branch)
    let pin = "refs/moonhub/pipelines/" + @identity.random_hex(16)
    let mut committed = false
    // Pin first: a crash may leave an orphan pin, but never a committed run whose
    // source is unprotected. Later recovery can reconcile orphan pins.
    ignore(
      @gitops.merge_git(
        git_dir,
        ["update-ref", "--no-deref", "--stdin"],
        input="create \{pin} \{sha}\n",
      ),
    )
    defer (if !committed {
      @async.protect_from_cancel(() => {
        ignore(
          @gitops.merge_git(git_dir, [
            "update-ref", "--no-deref", "-d", pin, sha,
          ]),
        )
      }) catch {
        _ => println("pipeline snapshot cleanup failed for \{pin}")
      }
    })
    let source = read_workflow_source(git_dir, sha, workflow_path)
    let definition = read_workflow_definition(git_dir, sha, source, jobs~) catch {
      @workflow.InvalidWorkflow(message) => raise @domain.BadRequest(message~)
      err => raise err
    }
    let triggers = @workflow.triggers(source)
    guard scheduled_minute >= 0L || triggers.dispatch || !jobs.is_empty() else {
      raise @domain.BadRequest(
        message="workflow does not allow manual dispatch",
      )
    }
    if scheduled_minute >= 0L {
      guard schedules_due(triggers.schedules, scheduled_minute * 60000L) else {
        raise @domain.BadRequest(
          message="workflow schedule changed before snapshot",
        )
      }
    }
    let inputs = try {
      if scheduled_minute >= 0L {
        Map([])
      } else {
        @workflow.resolve_dispatch_inputs(triggers.inputs, inputs)
      }
    } catch {
      @workflow.InvalidWorkflow(message) => raise @domain.BadRequest(message~)
    }
    let context : @workflow.RunContext = {
      repository: repo.owner + "/" + repo.name,
      sha,
      event_name: if scheduled_minute >= 0L {
        "schedule"
      } else {
        "workflow_dispatch"
      },
      head_ref: "",
      base_ref: "",
      inputs,
      variables: Map([]),
      release_tag: None,
      event: None,
    }
    let definition = @workflow.resolve_context(definition, context) catch {
      @workflow.InvalidWorkflow(message) => raise @domain.BadRequest(message~)
    }
    // Git subprocesses yield. Recheck permissions after the final await and
    // before the synchronous database transaction publishes the snapshot.
    ignore(@runtime.require_run_author(pool, actor, repo))
    let name = if definition.name.is_empty() {
      workflow_path
    } else {
      definition.name
    }
    let run = pool.with_client(client => {
      client.with_transaction(tx => {
        if scheduled_minute >= 0L {
          guard tx.query_opt(
              "SELECT s.repository_id FROM pipeline_schedule_config s JOIN repository r ON r.id=s.repository_id WHERE s.repository_id=? AND s.enabled=1 AND s.actor_id=? AND r.default_branch=?",
              params=[scope.id, actor.id, branch],
            )
            is Some(_) else {
            raise @domain.Forbidden(message="schedule changed before snapshot")
          }
        }
        let run = insert_run_snapshot(
          tx,
          scope.id,
          actor.id,
          workflow_path,
          name,
          branch,
          sha,
          pin,
          source,
          definition,
          context=Some(context),
        )
        if scheduled_minute >= 0L {
          ignore(
            tx.execute(
              "INSERT INTO pipeline_schedule_tick(repository_id,workflow_path,minute,run_id) VALUES(?,?,?,?)",
              params=[scope.id, workflow_path, scheduled_minute, run.id],
            ),
          )
        }
        run
      })
    })
    committed = true
    run
  })
}

///|
pub async fn rerun_run(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
  failed_only~ : Bool = false,
) -> @runtime.Run {
  let scope = @runtime.require_run_author(pool, actor, repo)
  let previous = @runtime.get_run(pool, actor, repo, number)
  guard previous.state is Completed else {
    raise @domain.BadRequest(
      message="only completed pipeline runs can be rerun",
    )
  }
  @repository.with_repository_write(pool, root, actor, scope, (scope, git_dir) => {
    ignore(@runtime.require_run_author(pool, actor, repo))
    let merge_check_id : Int64 = pool.with_client(client => {
      client
      .query_one(
        "SELECT COALESCE(merge_check_id, 0) AS check_id FROM pipeline_run WHERE id = ?",
        params=[previous.id],
      )
      .get_name("check_id")
    })
    if merge_check_id != 0L {
      validate_merge_check_rerun(
        pool,
        scope,
        git_dir,
        merge_check_id,
        previous.number,
      )
    }
    let pin = "refs/moonhub/pipelines/" + @identity.random_hex(16)
    let mut committed = false
    ignore(
      @gitops.merge_git(
        git_dir,
        ["update-ref", "--no-deref", "--stdin"],
        input="create \{pin} \{previous.commit_sha}\n",
      ),
    )
    defer (if !committed {
      @async.protect_from_cancel(() => {
        ignore(
          @gitops.merge_git(git_dir, [
            "update-ref",
            "--no-deref",
            "-d",
            pin,
            previous.commit_sha,
          ]),
        )
      }) catch {
        _ => println("pipeline rerun snapshot cleanup failed for \{pin}")
      }
    })
    ignore(@runtime.require_run_author(pool, actor, repo))
    let run = pool.with_client(client => {
      client.with_transaction(tx => {
        let rerun = insert_run_snapshot(
          tx,
          scope.id,
          actor.id,
          previous.workflow_path,
          previous.workflow_name,
          previous.source_branch,
          previous.commit_sha,
          pin,
          previous.workflow_source,
          previous.definition,
          definition_version=previous.definition_version,
          context=previous.context,
          merge_check_id~,
          cache_scope_source=previous.id,
          capture_variables=false,
          failed_only~,
        )
        ignore(
          tx.execute(
            "INSERT INTO pipeline_job_environment(job_id,environment_json) SELECT current.id,pinned.environment_json FROM pipeline_job current JOIN pipeline_job old ON old.job_key=current.job_key JOIN pipeline_job_environment pinned ON pinned.job_id=old.id WHERE current.run_id=? AND old.run_id=?",
            params=[rerun.id, previous.id],
          ),
        )
        rerun
      })
    })
    committed = true
    run
  })
}
