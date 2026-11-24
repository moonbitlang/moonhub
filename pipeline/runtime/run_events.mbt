///|
fn capture_run_event(
  tx : @database.DbTransaction,
  context : @workflow.RunContext,
  branch : String,
  event_id : Int64,
  merge_check_id : Int64,
) -> @workflow.RunContext raise {
  if context.event is Some(_) {
    return context
  }
  let event = run_event_context(
    context,
    event_ref=run_event_ref(Some(context), branch),
  )
  if event_id != 0L && context.event_name == "push" {
    let source = tx.query_one(
      "SELECT reference,old_sha,new_sha FROM repository_ref_event WHERE id=?",
      params=[event_id],
    )
    event["ref"] = Json::string(source.get_name("reference"))
    event["before"] = Json::string(source.get_name("old_sha"))
    event["after"] = Json::string(source.get_name("new_sha"))
  }
  if merge_check_id != 0L {
    let source = tx.query_one(
      "SELECT m.number,m.workflow_event,m.title,m.description,m.draft,m.status,m.source_branch,m.target_branch,v.source_sha,v.target_sha FROM merge_check c JOIN merge_request m ON m.id=c.merge_request_id JOIN merge_revision v ON v.merge_request_id=m.id AND v.version=c.version WHERE c.id=?",
      params=[merge_check_id],
    )
    let number : Int64 = source.get_name("number")
    event["action"] = Json::string(source.get_name("workflow_event"))
    event["number"] = Json::number(number.to_double())
    event["ref"] = Json::string("refs/pull/" + number.to_string() + "/merge")
    event["pull_request"] = {
      "number": number.to_double(),
      "title": (source.get_name("title") : String),
      "body": (source.get_name("description") : String),
      "draft": (source.get_name("draft") : Bool),
      "state": (source.get_name("status") : String),
      "head": {
        "sha": (source.get_name("source_sha") : String),
        "ref": (source.get_name("source_branch") : String),
        "repo": { "full_name": context.repository },
      },
      "base": {
        "sha": (source.get_name("target_sha") : String),
        "ref": (source.get_name("target_branch") : String),
        "repo": { "full_name": context.repository },
      },
    }
  }
  guard @utf8.encode(ToJson::to_json(event).stringify()).length() <= 196608 else {
    raise @domain.BadRequest(message="event snapshot exceeds 192 KiB")
  }
  { ..context, event: Some(event), }
}

///|
fn reuse_successful_jobs(
  tx : @database.DbTransaction,
  run_id : Int64,
  source : Int64,
) -> Unit raise {
  let failed = tx.query_all(
    "SELECT job_key FROM pipeline_job WHERE run_id=? AND COALESCE(actual_conclusion,conclusion) IN ('failure','timed_out','lost','cancelled')",
    params=[source],
  )
  guard !failed.is_empty() else {
    raise @domain.BadRequest(message="run has no failed jobs to rerun")
  }
  let affected : Set[String] = Set([])
  for row in failed {
    affected.add(row.get_name("job_key"))
  }
  let edges = tx.query_all(
    "SELECT job_key,needs_job_key FROM pipeline_job_need WHERE run_id=?",
    params=[source],
  )
  for _ in 0..<256 {
    let before = affected.length()
    for edge in edges {
      if affected.contains(edge.get_name("needs_job_key")) {
        affected.add(edge.get_name("job_key"))
      }
    }
    if affected.length() == before {
      break
    }
  }
  for
    row in tx.query_all(
      "SELECT current.id,old.job_key,old.conclusion,COALESCE(old.actual_conclusion,old.conclusion) AS actual_conclusion,COALESCE(reuse.source_job_id,old.id) AS source FROM pipeline_job current JOIN pipeline_job old ON old.job_key=current.job_key LEFT JOIN pipeline_job_reuse reuse ON reuse.job_id=old.id WHERE current.run_id=? AND old.run_id=? AND old.status='completed' AND current.status='waiting' AND NOT EXISTS (SELECT 1 FROM pipeline_matrix_expansion e WHERE e.job_id=old.id)",
      params=[run_id, source],
    ) {
    if !affected.contains(row.get_name("job_key")) {
      let id : Int64 = row.get_name("id")
      ignore(
        tx.execute(
          "INSERT INTO pipeline_job_reuse(job_id,source_job_id) VALUES(?,?)",
          params=[id, (row.get_name("source") : Int64)],
        ),
      )
      ignore(
        tx.execute(
          "UPDATE pipeline_job SET status='completed',conclusion=?,actual_conclusion=? WHERE id=?",
          params=[
            (row.get_name("conclusion") : String),
            (row.get_name("actual_conclusion") : String),
            id,
          ],
        ),
      )
    }
  }
}
