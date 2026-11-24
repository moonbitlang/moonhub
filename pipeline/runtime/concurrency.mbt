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
  if tx.query_opt("SELECT job_id FROM pipeline_call_expansion WHERE job_id=?", params=[
      job_id,
    ])
    is Some(_) {
    let key : String = tx
      .query_one("SELECT job_key FROM pipeline_job WHERE id=?", params=[job_id])
      .get_name("job_key")
    cancel_reusable_call(tx, run_id, job_id, key)
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
  // A job cannot wait for the workflow or reusable call that contains it.
  guard !existing.any(row => {
    job_id is Some(_) &&
    (row.get_name("run_id") : Int64) == run.id &&
    (row.get_name("job_id") : Int64?) is None
  }) else {
    raise @domain.BadRequest(
      message="job concurrency group conflicts with its workflow group",
    )
  }
  if job_id is Some(job_id) &&
    tx.query_opt(
      "SELECT s.id FROM pipeline_concurrency_live s JOIN pipeline_job caller ON caller.id=s.job_id JOIN pipeline_job child ON child.id=? AND child.run_id=s.run_id WHERE s.repository_id=? AND s.group_key=? AND substr(child.job_key,1,length(caller.job_key)+1)=caller.job_key||'/' LIMIT 1",
      params=[job_id, run.repository_id, key],
    )
    is Some(_) {
    raise @domain.BadRequest(
      message="job concurrency group conflicts with its reusable caller group",
    )
  }
  if queue_max &&
    existing.filter(row => !(row.get_name("admitted") : Bool)).length() >= 100 {
    cancel_concurrency_holder(tx, run.id, job_id)
    return
  }
  // Workflows and reusable calls retain their slots while descendants wait.
  // Walk the admitted holders and reject arrivals that close a dependency cycle.
  if job_id is Some(_) &&
    !cancel &&
    tx.query_opt(
      (
        #|WITH RECURSIVE blocked(id,run_id,job_key) AS (
        #|  SELECT holder.id, holder.run_id, job.job_key FROM pipeline_concurrency_live holder
        #|  LEFT JOIN pipeline_job job ON job.id=holder.job_id
        #|  WHERE holder.repository_id=? AND holder.group_key=? AND holder.admitted=1 AND holder.cancel_requested=0
        #|  UNION
        #|  SELECT holder.id, holder.run_id, job.job_key FROM blocked
        #|  JOIN pipeline_concurrency_live waiter ON waiter.run_id=blocked.run_id
        #|  JOIN pipeline_job child ON child.id=waiter.job_id
        #|  JOIN pipeline_concurrency_live holder ON holder.repository_id=waiter.repository_id AND holder.group_key=waiter.group_key
        #|  LEFT JOIN pipeline_job job ON job.id=holder.job_id
        #|  WHERE waiter.admitted=0 AND waiter.cancel_requested=0 AND holder.admitted=1 AND holder.cancel_requested=0
        #|    AND (blocked.job_key IS NULL OR substr(child.job_key,1,length(blocked.job_key)+1)=blocked.job_key||'/')
        #|)
        #|SELECT blocked.id FROM blocked JOIN pipeline_job arrival ON arrival.id=? AND arrival.run_id=blocked.run_id
        #|WHERE blocked.job_key IS NULL OR substr(arrival.job_key,1,length(blocked.job_key)+1)=blocked.job_key||'/'
        #|LIMIT 1
      ),
      params=[run.repository_id, key, job_id.unwrap()],
    )
    is Some(_) {
    raise @domain.BadRequest(
      message="job concurrency would deadlock admitted workflows or reusable calls",
    )
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
