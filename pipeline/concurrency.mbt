///|
// This is called within the same write transaction that publishes the snapshot.
// A cancelled holder retains its slot until every leased process is fenced.
fn schedule_run(
  tx : @database.DbTransaction,
  run : Run,
  merge_check_id : Int64,
) -> Unit raise {
  guard run.definition.concurrency is Some(policy) else { return }
  let reference = if merge_check_id != 0L {
    let number : Int64 = tx
      .query_one(
        "SELECT m.number FROM merge_check c JOIN merge_request m ON m.id=c.merge_request_id WHERE c.id=?",
        params=[merge_check_id],
      )
      .get_name("number")
    "refs/pull/" + number.to_string() + "/merge"
  } else {
    "refs/heads/" + run.source_branch
  }
  let github : Map[String, Json] = {
    "workflow": Json::string(run.workflow_name),
    "ref": Json::string(reference),
    "repository": Json::string(
      run.context.map(ctx => ctx.repository).unwrap_or(""),
    ),
    "sha": Json::string(run.commit_sha),
    "head_ref": Json::string(run.context.map(ctx => ctx.head_ref).unwrap_or("")),
    "base_ref": Json::string(run.context.map(ctx => ctx.base_ref).unwrap_or("")),
    "event_name": Json::string(
      run.context.map(ctx => ctx.event_name).unwrap_or("workflow_dispatch"),
    ),
    "run_id": Json::string(run.id.to_string()),
  }
  let (key, cancel) = policy.resolve(github) catch {
    @workflow.InvalidWorkflow(message) => raise @domain.BadRequest(message~)
  }
  for
    row in tx.query_all(
      "SELECT s.run_id,s.admitted FROM pipeline_run_schedule s JOIN pipeline_run r ON r.id=s.run_id WHERE s.repository_id=? AND s.group_key=? AND r.status <> 'completed' ORDER BY r.id",
      params=[run.repository_id, key],
    ) {
    if cancel || !(row.get_name("admitted") : Bool) {
      cancel_check_run(tx, row.get_name("run_id"))
    }
  }
  let active = tx.query_opt(
      "SELECT s.run_id FROM pipeline_run_schedule s JOIN pipeline_run r ON r.id=s.run_id WHERE s.repository_id=? AND s.group_key=? AND s.admitted=1 AND r.status <> 'completed' LIMIT 1",
      params=[run.repository_id, key],
    )
    is Some(_)
  ignore(
    tx.execute(
      "INSERT INTO pipeline_run_schedule(run_id,repository_id,group_key,admitted) VALUES(?,?,?,?)",
      params=[run.id, run.repository_id, key, !active],
    ),
  )
}

///|
fn advance_concurrency(tx : @database.DbTransaction) -> Unit raise {
  // No in-memory ownership: restart and multiple coordinator processes use the
  // same transactional admission predicate. New arrivals replace older waiters.
  ignore(
    tx.execute(
      "UPDATE pipeline_run_schedule AS pending SET admitted=1 WHERE admitted=0 AND EXISTS (SELECT 1 FROM pipeline_run r WHERE r.id=pending.run_id AND r.status <> 'completed' AND r.cancel_requested=0) AND NOT EXISTS (SELECT 1 FROM pipeline_run_schedule active JOIN pipeline_run r ON r.id=active.run_id WHERE active.repository_id=pending.repository_id AND active.group_key=pending.group_key AND active.admitted=1 AND r.status <> 'completed') AND NOT EXISTS (SELECT 1 FROM pipeline_run_schedule newer JOIN pipeline_run r ON r.id=newer.run_id WHERE newer.repository_id=pending.repository_id AND newer.group_key=pending.group_key AND newer.admitted=0 AND newer.run_id>pending.run_id AND r.status <> 'completed')",
    ),
  )
}
