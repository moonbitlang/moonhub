///|
priv suberror SnapshotError {
  SnapshotError(String)
}

///|
fn require_run_author(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> @repository.RepositoryScope raise {
  let current = @identity.active_user_by_name(pool, actor.name_key)
  guard current.id == actor.id else {
    raise @domain.Unauthorized(message="account changed")
  }
  let scope = @repository.repository_scope(pool, current, repo)
  @repository.authorize_repository(pool, current, repo, Write)
  guard @identity.can_manage_team(pool, current, scope.team_id) else {
    raise @domain.Forbidden(
      message="repository owner or admin required to create a pipeline run",
    )
  }
  scope
}

///|
fn validate_workflow_path(path : String) -> Unit raise {
  let parts = path.split("/").collect()
  guard parts.length() == 3 &&
    parts[0] == ".github" &&
    parts[1] == "workflows" &&
    path.length() <= 240 &&
    (path.has_suffix(".yml") || path.has_suffix(".yaml")) &&
    parts[2].length() > 4 &&
    parts[2].get_char(0) is Some(first) &&
    (first.is_ascii_alphabetic() || first.is_ascii_digit() || first == '_') &&
    parts[2]
    .iter()
    .all(ch => {
      ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ch == '_' ||
      ch == '-' ||
      ch == '.'
    }) else {
    raise @domain.BadRequest(
      message="workflow must be a YAML file directly under .github/workflows",
    )
  }
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
fn insert_run_snapshot(
  tx : @database.DbTransaction,
  repository_id : Int64,
  actor_id : Int64,
  workflow_path : String,
  workflow_name : String,
  branch : String,
  sha : String,
  pin : String,
  source : String,
  definition : @workflow.Workflow,
  definition_version~ : Int32 = @workflow.format_version,
  context~ : @workflow.RunContext? = None,
  event_id~ : Int64 = 0L,
  merge_check_id~ : Int64 = 0L,
  cache_scope_source~ : Int64 = 0L,
  capture_variables~ : Bool = true,
) -> Run raise {
  let context = if definition_version >= 6 && capture_variables {
    context.map(context => {
      ..context,
      variables: snapshot_variables(tx, repository_id),
    })
  } else {
    context
  }
  validate_secret_policy(
    tx, repository_id, branch, workflow_path, context, definition,
  )
  let number : Int64 = tx
    .query_one(
      "SELECT COALESCE(MAX(number), 0) + 1 AS number FROM pipeline_run WHERE repository_id = ?",
      params=[repository_id],
    )
    .get_name("number")
  let display_title = if definition.run_name.is_empty() {
    workflow_name
  } else {
    let github : Map[String, Json] = {
      "repository": context.map(c => c.repository).unwrap_or(""),
      "sha": sha,
      "event_name": context
      .map(c => c.event_name)
      .unwrap_or("workflow_dispatch"),
      "ref": "refs/heads/" + branch,
      "actor": (
        tx
        .query_one("SELECT name_key FROM user WHERE id=?", params=[actor_id])
        .get_name("name_key") : String),
      "workflow": workflow_name,
    }
    let title = @workflow.scheduling_template(definition.run_name, {
      "github": ToJson::to_json(github),
      "inputs": ToJson::to_json(context.map(c => c.inputs).unwrap_or(Map([]))),
    }) catch {
      @workflow.InvalidWorkflow(message) => raise @domain.BadRequest(message~)
    }
    guard !title.is_empty() &&
      @utf8.encode(title).length() <= 512 &&
      !title.contains("\u0000") else {
      raise @domain.BadRequest(message="run-name requires 1 to 512 UTF-8 bytes")
    }
    title
  }
  let row = tx.query_one(
    "INSERT INTO pipeline_run (repository_id, number, requested_by_user_id, workflow_path, workflow_name, display_title, source_branch, commit_sha, source_ref, definition_version, workflow_source, definition_json, trigger_event_id, merge_check_id, context_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULLIF(?, 0), NULLIF(?, 0), NULLIF(?, '')) RETURNING *",
    params=[
      repository_id,
      number,
      actor_id,
      workflow_path,
      workflow_name,
      display_title,
      branch,
      sha,
      pin,
      definition_version.to_int64(),
      source,
      ToJson::to_json(definition).stringify(),
      event_id,
      merge_check_id,
      context.map(value => ToJson::to_json(value).stringify()).unwrap_or(""),
    ],
  )
  let run = Run::from_row(row)
  snapshot_cache_scope(tx, run, merge_check_id, source=cache_scope_source)
  if merge_check_id != 0L {
    ignore(
      tx.execute(
        "UPDATE merge_check SET run_number = ?, requested_by_user_id = ?, state = 'queued', conclusion = '', last_error = '' WHERE id = ?",
        params=[number, actor_id, merge_check_id],
      ),
    )
  }
  for ordinal, job in definition.jobs {
    let _ = tx.execute(
      "INSERT INTO pipeline_job (run_id, job_key, ordinal, status, matrix_group, max_parallel, matrix_fail_fast) VALUES (?, ?, ?, ?, ?, ?, ?)",
      params=[
        run.id,
        job.id,
        ordinal.to_int64(),
        if definition_version >= 4 || !job.needs.is_empty() {
          "waiting"
        } else {
          "queued"
        },
        job.matrix_group,
        job.max_parallel.to_int64(),
        job.fail_fast,
      ],
    )
  }
  for job in definition.jobs {
    let job_id : Int64 = tx
      .query_one(
        "SELECT id FROM pipeline_job WHERE run_id = ? AND job_key = ?",
        params=[run.id, job.id],
      )
      .get_name("id")
    for label in job.runs_on {
      let _ = tx.execute(
        "INSERT INTO pipeline_job_label (job_id, label) VALUES (?, ?)",
        params=[job_id, label],
      )
    }
    for need in job.needs {
      let _ = tx.execute(
        "INSERT INTO pipeline_job_need (run_id, job_key, needs_job_key) VALUES (?, ?, ?)",
        params=[run.id, job.id, need],
      )
    }
  }
  schedule_run(tx, run)
  if definition_version >= 4 {
    advance_run_jobs(tx, run.id)
    finalize_run(tx, run.id)
    return Run::from_row(
      tx.query_one("SELECT * FROM pipeline_run WHERE id=?", params=[run.id]),
    )
  }
  run
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
) -> Run {
  create_run_event(
    pool,
    root,
    actor,
    repo,
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
  repo : @domain.RepoId,
  branch : String,
  workflow_path : String,
  inputs~ : Map[String, Json] = Map([]),
  jobs~ : Array[String] = [],
  scheduled_minute~ : Int64 = -1L,
) -> Run {
  ignore(require_run_author(pool, actor, repo))
  validate_workflow_path(workflow_path)
  @repository.with_repository_write(pool, root, actor, repo, (scope, git_dir) => {
    ignore(require_run_author(pool, actor, repo))
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
        return Run::from_row(previous)
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
    let definition = @workflow.parse(source, jobs~) catch {
      @workflow.InvalidWorkflow(message) => raise @domain.BadRequest(message~)
    }
    let triggers = @workflow.triggers(source)
    guard scheduled_minute >= 0L || triggers.dispatch || !jobs.is_empty() else {
      raise @domain.BadRequest(
        message="workflow does not allow manual dispatch",
      )
    }
    if scheduled_minute >= 0L {
      let utc = pool.with_client(c => {
        c.query_one(
          "SELECT CAST(strftime('%M',?*60,'unixepoch') AS INTEGER) minute,CAST(strftime('%H',?*60,'unixepoch') AS INTEGER) hour,CAST(strftime('%d',?*60,'unixepoch') AS INTEGER) day,CAST(strftime('%m',?*60,'unixepoch') AS INTEGER) month,CAST(strftime('%w',?*60,'unixepoch') AS INTEGER) weekday",
          params=[
            scheduled_minute, scheduled_minute, scheduled_minute, scheduled_minute,
            scheduled_minute,
          ],
        )
      })
      guard triggers.schedules.any(cron => {
        @workflow.cron_matches(
          cron,
          (utc.get_name("minute") : Int64).to_int(),
          (utc.get_name("hour") : Int64).to_int(),
          (utc.get_name("day") : Int64).to_int(),
          (utc.get_name("month") : Int64).to_int(),
          (utc.get_name("weekday") : Int64).to_int(),
        )
      }) else {
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
    }
    let definition = @workflow.resolve_context(definition, context) catch {
      @workflow.InvalidWorkflow(message) => raise @domain.BadRequest(message~)
    }
    // Git subprocesses yield. Recheck permissions after the final await and
    // before the synchronous database transaction publishes the snapshot.
    ignore(require_run_author(pool, actor, repo))
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
) -> Run {
  let previous = get_run(pool, actor, repo, number)
  guard previous.state is Completed else {
    raise @domain.BadRequest(
      message="only completed pipeline runs can be rerun",
    )
  }
  @repository.with_repository_write(pool, root, actor, repo, (scope, git_dir) => {
    ignore(require_run_author(pool, actor, repo))
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
    ignore(require_run_author(pool, actor, repo))
    let run = pool.with_client(client => {
      client.with_transaction(tx => {
        insert_run_snapshot(
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
        )
      })
    })
    committed = true
    run
  })
}
