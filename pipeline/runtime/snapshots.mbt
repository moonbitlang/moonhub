///|
pub fn insert_run_snapshot(
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
    let event_ref = run_event_ref(context, branch)
    let github : Map[String, Json] = {
      "repository": context.map(c => c.repository).unwrap_or(""),
      "sha": sha,
      "event_name": context
      .map(c => c.event_name)
      .unwrap_or("workflow_dispatch"),
      "ref": event_ref,
      "actor": (
        tx
        .query_one("SELECT name_key FROM user WHERE id=?", params=[actor_id])
        .get_name("name_key") : String),
      "workflow": workflow_name,
    }
    if context is Some(saved) && saved.release_tag is Some(_) {
      github["event"] = ToJson::to_json(run_event_context(saved, event_ref~))
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
