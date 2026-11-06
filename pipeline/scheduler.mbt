///|
fn advance_run_jobs(tx : @database.DbTransaction, run_id : Int64) -> Unit raise {
  // Claim reconciliation visits active runs too. Avoid decoding a potentially
  // 1-MiB snapshot when every job is already queued or executing.
  if tx.query_opt(
      "SELECT id FROM pipeline_job WHERE run_id=? AND status='waiting' LIMIT 1",
      params=[run_id],
    )
    is None {
    return
  }
  let run = Run::from_row(
    tx.query_one("SELECT * FROM pipeline_run WHERE id=?", params=[run_id]),
  )
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
      if !needs.all(need => (need.get_name("status") : String) == "completed") {
        continue
      }
      let allowed = if run.definition_version >= 4 {
        let job = run.definition.jobs
          .iter()
          .find_first(job => job.id == job_key)
          .unwrap()
        let ancestors = tx.query_all(
          "WITH RECURSIVE ancestors(job_key) AS (SELECT needs_job_key FROM pipeline_job_need WHERE run_id=? AND job_key=? UNION SELECT n.needs_job_key FROM pipeline_job_need n JOIN ancestors a ON a.job_key=n.job_key WHERE n.run_id=?) SELECT j.conclusion FROM ancestors a JOIN pipeline_job j ON j.run_id=? AND j.job_key=a.job_key",
          params=[run_id, job_key, run_id, run_id],
        )
        let success = ancestors.all(row => {
          (row.get_name("conclusion") : String?) == Some("success")
        })
        let failure = ancestors.any(row => {
          ["failure", "timed_out", "lost"].contains(
            (row.get_name("conclusion") : String?).unwrap_or(""),
          )
        })
        let cancelled = ancestors.any(row => {
          (row.get_name("conclusion") : String?) == Some("cancelled")
        })
        let github = run_job_github(tx, run)
        let context = job_needs_context(tx, run_id, job)
        Some(
          @workflow.job_condition(
            job.condition,
            github,
            context,
            inputs=run.context.map(ctx => ctx.inputs).unwrap_or(Map([])),
            variables=if run.definition_version >= 6 {
              Some(run.context.map(ctx => ctx.variables).unwrap_or(Map([])))
            } else {
              None
            },
            success~,
            failure~,
            cancelled~,
          ),
        ) catch {
          @workflow.InvalidWorkflow(_) => None
        }
      } else {
        Some(
          needs.all(need => {
            (need.get_name("conclusion") : String?) == Some("success")
          }),
        )
      }
      // Invalid data-dependent expressions fail this job, never roll back the
      // producer completion or wedge every claim/lease reconciliation.
      ignore(
        tx.execute(
          match allowed {
            Some(true) =>
              "UPDATE pipeline_job SET status='queued' WHERE id=? AND status='waiting'"
            Some(false) =>
              "UPDATE pipeline_job SET status='completed',conclusion='skipped' WHERE id=? AND status='waiting'"
            None =>
              "UPDATE pipeline_job SET status='completed',conclusion='failure' WHERE id=? AND status='waiting'"
          },
          params=[job_id],
        ),
      )
      changed = true
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
