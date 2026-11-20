///|
pub fn cancel_run_in_transaction(
  tx : @database.DbTransaction,
  run_id : Int64,
) -> Unit raise {
  ignore(
    tx.execute(
      "UPDATE pipeline_run SET cancel_requested = 1 WHERE id = ? AND status <> 'completed'",
      params=[run_id],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job SET status = 'completed', conclusion = 'cancelled' WHERE run_id = ? AND status IN ('queued', 'waiting')",
      params=[run_id],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job_attempt SET cancel_at_ms = COALESCE(cancel_at_ms, CAST(strftime('%s', 'now') AS INTEGER) * 1000) WHERE status <> 'completed' AND job_id IN (SELECT id FROM pipeline_job WHERE run_id = ?)",
      params=[run_id],
    ),
  )
  finalize_run(tx, run_id)
}
