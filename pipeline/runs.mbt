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
  event_id? : Int64 = 0L,
  merge_check_id? : Int64 = 0L,
) -> Run raise {
  let number : Int64 = tx
    .query_one(
      "SELECT COALESCE(MAX(number), 0) + 1 AS number FROM pipeline_run WHERE repository_id = ?",
      params=[repository_id],
    )
    .get_name("number")
  let row = tx.query_one(
    "INSERT INTO pipeline_run (repository_id, number, requested_by_user_id, workflow_path, workflow_name, source_branch, commit_sha, source_ref, definition_version, workflow_source, definition_json, trigger_event_id, merge_check_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULLIF(?, 0), NULLIF(?, 0)) RETURNING *",
    params=[
      repository_id,
      number,
      actor_id,
      workflow_path,
      workflow_name,
      branch,
      sha,
      pin,
      @workflow.format_version.to_int64(),
      source,
      ToJson::to_json(definition).stringify(),
      event_id,
      merge_check_id,
    ],
  )
  let run = Run::from_row(row)
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
      "INSERT INTO pipeline_job (run_id, job_key, ordinal, status) VALUES (?, ?, ?, ?)",
      params=[
        run.id,
        job.id,
        ordinal.to_int64(),
        if job.needs.is_empty() {
          "queued"
        } else {
          "waiting"
        },
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
) -> Run {
  ignore(require_run_author(pool, actor, repo))
  validate_workflow_path(workflow_path)
  @repository.with_repository_write(pool, root, actor, repo, (scope, git_dir) => {
    ignore(require_run_author(pool, actor, repo))
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
    let definition = @workflow.parse(source) catch {
      @workflow.InvalidWorkflow(message) => raise @domain.BadRequest(message~)
    }
    guard @workflow.triggers(source).dispatch else {
      raise @domain.BadRequest(
        message="workflow does not allow manual dispatch",
      )
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
        insert_run_snapshot(
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
        )
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
          merge_check_id~,
        )
      })
    })
    committed = true
    run
  })
}
