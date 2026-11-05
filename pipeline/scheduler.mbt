///|
fn advance_run_jobs(tx : @database.DbTransaction, run_id : Int64) -> Unit raise {
  // Expanded workflows are bounded to 256 jobs. A fixed point keeps
  // deeper branches from remaining waiting after an upstream failure.
  for pass = 0; pass < 256; pass = pass + 1 {
    let mut changed = false
    let waiting = tx.query_all(
      "SELECT id, job_key FROM pipeline_job WHERE run_id = ? AND status = 'waiting' ORDER BY ordinal",
      params=[run_id],
    )
    for row in waiting {
      let job_id : Int64 = row.get_name("id")
      let job_key : String = row.get_name("job_key")
      let needs = tx.query_all(
        "SELECT j.status, j.conclusion FROM pipeline_job_need n JOIN pipeline_job j ON j.run_id = n.run_id AND j.job_key = n.needs_job_key WHERE n.run_id = ? AND n.job_key = ?",
        params=[run_id, job_key],
      )
      let mut all_completed = true
      let mut dependency_failed = false
      for need in needs {
        let status : String = need.get_name("status")
        let conclusion : String? = need.get_name("conclusion")
        if status != "completed" {
          all_completed = false
        } else if conclusion != Some("success") {
          dependency_failed = true
        }
      }
      if dependency_failed && all_completed {
        let _ = tx.execute(
          "UPDATE pipeline_job SET status = 'completed', conclusion = 'skipped' WHERE id = ? AND status = 'waiting'",
          params=[job_id],
        )
        changed = true
      } else if all_completed {
        let _ = tx.execute(
          "UPDATE pipeline_job SET status = 'queued' WHERE id = ? AND status = 'waiting'",
          params=[job_id],
        )
        changed = true
      }
    }
    if !changed {
      return
    }
  }
  raise InvalidRecord
}

///|
fn advance_all_runs(tx : @database.DbTransaction) -> Unit raise {
  advance_concurrency(tx)
  let runs = tx.query_all(
    "SELECT id FROM pipeline_run WHERE status IN ('queued', 'running') ORDER BY id LIMIT 100",
  )
  for row in runs {
    let run_id : Int64 = row.get_name("id")
    advance_run_jobs(tx, run_id)
    finalize_run(tx, run_id)
  }
}

///|
fn cancel_matrix_siblings(
  tx : @database.DbTransaction,
  job_id : Int64,
  conclusion : String,
  now : Int64,
) -> Unit raise {
  guard ["failure", "timed_out", "lost"].contains(conclusion) else { return }
  let job = tx.query_one(
    "SELECT run_id,matrix_group,matrix_fail_fast FROM pipeline_job WHERE id=?",
    params=[job_id],
  )
  let group : String = job.get_name("matrix_group")
  guard !group.is_empty() && (job.get_name("matrix_fail_fast") : Bool) else {
    return
  }
  let run : Int64 = job.get_name("run_id")
  ignore(
    tx.execute(
      "UPDATE pipeline_job SET status='completed',conclusion='cancelled' WHERE run_id=? AND matrix_group=? AND status IN ('waiting','queued')",
      params=[run, group],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job_attempt SET cancel_at_ms=COALESCE(cancel_at_ms,?) WHERE status <> 'completed' AND job_id IN (SELECT id FROM pipeline_job WHERE run_id=? AND matrix_group=? AND id <> ?)",
      params=[now, run, group, job_id],
    ),
  )
}
