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
  if tx.query_opt(
      "SELECT run_id FROM pipeline_run_schedule WHERE run_id=? AND admitted=0",
      params=[run_id],
    )
    is Some(_) {
    return
  }
  let run = Run::from_row(
    tx.query_one("SELECT * FROM pipeline_run WHERE id=?", params=[run_id]),
  )
  // Expanded workflows are bounded to 256 jobs. A fixed point keeps
  // deeper branches from remaining waiting after an upstream failure.
  for _ in 0..<512 {
    let mut changed = false
    let waiting = tx.query_all(
      "SELECT id, job_key FROM pipeline_job WHERE run_id = ? AND status = 'waiting' ORDER BY ordinal",
      params=[run_id],
    )
    for row in waiting {
      let job_id : Int64 = row.get_name("id")
      let job_key : String = row.get_name("job_key")
      // Reserving a slot for an earlier job can cancel this job in the same pass.
      guard tx.query_opt(
          "SELECT id FROM pipeline_job WHERE id=? AND status='waiting'",
          params=[job_id],
        )
        is Some(_) else {
        continue
      }
      let job = saved_job(tx, run, job_id, job_key)
      let needs = tx.query_all(
        "SELECT j.status, j.conclusion FROM pipeline_job_need n JOIN pipeline_job j ON j.run_id = n.run_id AND j.job_key = n.needs_job_key WHERE n.run_id = ? AND n.job_key = ?",
        params=[run_id, job_key],
      )
      if !needs.all(need => (need.get_name("status") : String) == "completed") {
        continue
      }
      if job.reusable_call is Some(_) &&
        tx.query_opt(
          "SELECT job_id FROM pipeline_call_expansion WHERE job_id=?",
          params=[job_id],
        )
        is Some(_) {
        complete_call_barrier(tx, run, job_id, job)
        changed = true
        continue
      }
      if job.dynamic_matrix is Some(_) &&
        tx.query_opt(
          "SELECT job_id FROM pipeline_matrix_expansion WHERE job_id=?",
          params=[job_id],
        )
        is Some(_) {
        complete_matrix_barrier(tx, run, job_id, job_key)
        changed = true
        continue
      }
      let allowed = if run.definition_version >= 4 {
        let ancestors = tx.query_all(
          "WITH RECURSIVE ancestors(job_key) AS (SELECT needs_job_key FROM pipeline_job_need WHERE run_id=? AND job_key=? UNION SELECT n.needs_job_key FROM pipeline_job_need n JOIN ancestors a ON a.job_key=n.job_key WHERE n.run_id=?) SELECT j.conclusion FROM ancestors a JOIN pipeline_job j ON j.run_id=? AND j.job_key=a.job_key WHERE substr(j.job_key,1,length(?))=?",
          params=[
            run_id,
            job_key,
            run_id,
            run_id,
            job.context_prefix,
            job.context_prefix,
          ],
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
            inputs=job.call_inputs.unwrap_or(
              run.context.map(ctx => ctx.inputs).unwrap_or(Map([])),
            ),
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
      let allowed = if allowed == Some(true) {
        try {
          let context : Map[String, Json] = {
            "github": ToJson::to_json(run_job_github(tx, run)),
            "inputs": ToJson::to_json(
              job.call_inputs.unwrap_or(
                run.context.map(ctx => ctx.inputs).unwrap_or(Map([])),
              ),
            ),
            "vars": ToJson::to_json(
              run.context.map(ctx => ctx.variables).unwrap_or(Map([])),
            ),
            "needs": ToJson::to_json(job_needs_context(tx, run_id, job)),
            "matrix": ToJson::to_json(job.matrix),
            "strategy": ToJson::to_json(job.strategy),
          }
          if job.dynamic_matrix is Some(_) {
            expand_run_matrix(tx, run, job_id, job, context)
            changed = true
            continue
          }
          if job.containers is Some(_) &&
            job.runs_on.any(label => ["windows", "macos"].contains(label)) {
            raise @domain.BadRequest(
              message="Workflow containers require an isolated Linux CI provider.",
            )
          }
          if !admit_deployment(tx, run, job_id, job, context) {
            continue
          }
          let policy = @workflow.scheduling_expression(
            job.continue_on_error,
            context,
            extended=true,
          )
          guard policy is True || policy is False else {
            raise @domain.BadRequest(
              message="job.continue-on-error must evaluate to boolean",
            )
          }
          if job.concurrency is Some(concurrency) &&
            tx.query_opt(
              "SELECT id FROM pipeline_concurrency_slot WHERE job_id=?",
              params=[job_id],
            )
            is None {
            let inputs = if job.reusable_call is Some(call) &&
              call.definition.concurrency is Some(_) {
              resolve_call_inputs(tx, run_id, job, context)
            } else {
              job.call_inputs.unwrap_or(
                run.context.map(ctx => ctx.inputs).unwrap_or(Map([])),
              )
            }
            let (key, cancel) = concurrency.resolve(
              run_job_github(tx, run),
              inputs~,
              variables=Some(
                run.context.map(ctx => ctx.variables).unwrap_or(Map([])),
              ),
              job_context=Some(context),
            )
            reserve_concurrency(
              tx,
              run,
              Some(job_id),
              key,
              cancel,
              concurrency.queue_max,
            )
          }
          if job.reusable_call is Some(_) {
            if tx.query_opt(
                "SELECT id FROM pipeline_concurrency_slot WHERE job_id=? AND admitted=0",
                params=[job_id],
              )
              is Some(_) {
              continue
            }
            // Overflow or another holder may have cancelled this caller.
            if (
                tx
                .query_one("SELECT status FROM pipeline_job WHERE id=?", params=[
                  job_id,
                ])
                .get_name("status") : String) !=
              "waiting" {
              changed = true
              continue
            }
            expand_reusable_call(tx, run, job_id, job, context)
            changed = true
            continue
          }
          ignore(
            tx.execute(
              "UPDATE pipeline_job SET allow_failure=? WHERE id=? AND status='waiting'",
              params=[policy is True, job_id],
            ),
          )
          allowed
        } catch {
          @workflow.InvalidWorkflow(message) | @domain.BadRequest(message~) => {
            ignore(
              tx.execute(
                "UPDATE pipeline_job SET scheduling_error=? WHERE id=?",
                params=[message, job_id],
              ),
            )
            None
          }
          err => raise err
        }
      } else {
        allowed
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
  // Recheck queued approvals before they can consume a provider or a group slot.
  ignore(
    tx.execute(
      "DELETE FROM pipeline_concurrency_slot WHERE job_id IN (SELECT j.id FROM pipeline_job j JOIN pipeline_job_deployment d ON d.job_id=j.id WHERE j.status='queued' AND NOT EXISTS (SELECT 1 FROM pipeline_deployment_admission a WHERE a.job_id=j.id))",
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job SET status='waiting' WHERE status='queued' AND EXISTS (SELECT 1 FROM pipeline_job_deployment d WHERE d.job_id=pipeline_job.id) AND NOT EXISTS (SELECT 1 FROM pipeline_deployment_admission a WHERE a.job_id=pipeline_job.id)",
    ),
  )
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
