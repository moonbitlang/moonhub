///|
pub fn cancel_run_in_transaction(
  tx : @database.DbTransaction,
  run_id : Int64,
  now~ : Int64? = None,
) -> Unit raise {
  ignore(
    tx.execute(
      "UPDATE pipeline_run SET cancel_requested = 1,updated_at=datetime('now') WHERE id = ? AND status <> 'completed'",
      params=[run_id],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_call_expansion SET cancel_requested=1 WHERE job_id IN (SELECT id FROM pipeline_job WHERE run_id=? AND status<>'completed')",
      params=[run_id],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job SET status = 'completed', conclusion = 'cancelled' WHERE run_id = ? AND status IN ('queued', 'waiting') AND NOT EXISTS (SELECT 1 FROM pipeline_call_expansion e WHERE e.job_id=pipeline_job.id)",
      params=[run_id],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job_attempt SET cancel_at_ms = COALESCE(cancel_at_ms, COALESCE(NULLIF(?,0),CAST(strftime('%s', 'now') AS INTEGER) * 1000)) WHERE status <> 'completed' AND job_id IN (SELECT id FROM pipeline_job WHERE run_id = ?)",
      params=[now.unwrap_or(0L), run_id],
    ),
  )
  advance_run_jobs(tx, run_id)
  finalize_run(tx, run_id)
}
