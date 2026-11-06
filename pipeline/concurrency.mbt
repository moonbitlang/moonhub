///|
// This is called within the same write transaction that publishes the snapshot.
// A cancelled holder retains its slot until every leased process is fenced.
fn schedule_run(tx : @database.DbTransaction, run : Run) -> Unit raise {
  guard run.definition.concurrency is Some(policy) else { return }
  let github = run_job_github(tx, run)
  let inputs = run.context.map(ctx => ctx.inputs).unwrap_or(Map([]))
  let variables = if run.definition_version >= 6 {
    Some(run.context.map(ctx => ctx.variables).unwrap_or(Map([])))
  } else {
    None
  }
  let (key, cancel) = policy.resolve(github, inputs~, variables~) catch {
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
