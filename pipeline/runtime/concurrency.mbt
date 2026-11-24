///|
fn schedule_run(tx : @database.DbTransaction, run : Run) -> Unit raise {
  guard run.definition.concurrency is Some(policy) else { return }
  let (key, cancel) = policy.resolve(
    run_job_github(tx, run),
    inputs=run.context.map(ctx => ctx.inputs).unwrap_or(Map([])),
    variables=if run.definition_version >= 6 {
      Some(run.context.map(ctx => ctx.variables).unwrap_or(Map([])))
    } else {
      None
    },
  ) catch {
    @workflow.InvalidWorkflow(message) => raise @domain.BadRequest(message~)
    err => raise err
  }
  reserve_concurrency(tx, run, None, key, cancel, policy.queue_max)
}

///|
// A cancellation requests fencing; the holder is live until its job/run is
// completed by acknowledgement or lease expiry. Both scopes share one namespace.
fn cancel_concurrency_holder(
  tx : @database.DbTransaction,
  run_id : Int64,
  job_id : Int64?,
) -> Unit raise {
  guard job_id is Some(job_id) else {
    cancel_run_in_transaction(tx, run_id)
    return
  }
  ignore(
    tx.execute(
      "UPDATE pipeline_job SET status='completed',conclusion='cancelled' WHERE id=? AND status IN ('queued','waiting')",
      params=[job_id],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job_attempt SET cancel_at_ms=COALESCE(cancel_at_ms,CAST(strftime('%s','now') AS INTEGER)*1000) WHERE job_id=? AND status<>'completed'",
      params=[job_id],
    ),
  )
}

///|
fn reserve_concurrency(
  tx : @database.DbTransaction,
  run : Run,
  job_id : Int64?,
  key : String,
  cancel : Bool,
  queue_max : Bool,
) -> Unit raise {
  let existing = tx.query_all(
    "SELECT run_id,job_id,admitted FROM pipeline_concurrency_live WHERE repository_id=? AND group_key=? ORDER BY id",
    params=[run.repository_id, key],
  )
  // A job cannot wait for the workflow that contains it to finish.
  guard !existing.any(row => {
    job_id is Some(_) &&
    (row.get_name("run_id") : Int64) == run.id &&
    (row.get_name("job_id") : Int64?) is None
  }) else {
    raise @domain.BadRequest(
      message="job concurrency group conflicts with its workflow group",
    )
  }
  if queue_max &&
    existing.filter(row => !(row.get_name("admitted") : Bool)).length() >= 100 {
    cancel_concurrency_holder(tx, run.id, job_id)
    return
  }
  for row in existing {
    if cancel || (!queue_max && !(row.get_name("admitted") : Bool)) {
      cancel_concurrency_holder(
        tx,
        row.get_name("run_id"),
        row.get_name("job_id"),
      )
    }
  }
  // Advance old FIFO waiters before considering this arrival.
  advance_concurrency(tx)
  let active = tx.query_opt(
      "SELECT id FROM pipeline_concurrency_live WHERE repository_id=? AND group_key=? AND admitted=1 LIMIT 1",
      params=[run.repository_id, key],
    )
    is Some(_)
  ignore(
    tx.execute(
      "INSERT INTO pipeline_concurrency_slot(run_id,job_id,repository_id,group_key,admitted) VALUES(?,NULLIF(?,0),?,?,?)",
      params=[run.id, job_id.unwrap_or(0L), run.repository_id, key, !active],
    ),
  )
}

///|
fn advance_concurrency(tx : @database.DbTransaction) -> Unit raise {
  ignore(
    tx.execute(
      "UPDATE pipeline_concurrency_slot AS pending SET admitted=1 WHERE admitted=0 AND EXISTS (SELECT 1 FROM pipeline_concurrency_live s WHERE s.id=pending.id AND s.cancel_requested=0) AND NOT EXISTS (SELECT 1 FROM pipeline_concurrency_live active WHERE active.repository_id=pending.repository_id AND active.group_key=pending.group_key AND active.admitted=1) AND NOT EXISTS (SELECT 1 FROM pipeline_concurrency_live older WHERE older.repository_id=pending.repository_id AND older.group_key=pending.group_key AND older.admitted=0 AND older.cancel_requested=0 AND older.id<pending.id)",
    ),
  )
}
