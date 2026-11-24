///|
fn expand_reusable_call(
  tx : @database.DbTransaction,
  run : Run,
  job_id : Int64,
  job : @workflow.Job,
  context : Map[String, Json],
) -> Unit raise {
  let (inputs, children) = @workflow.instantiate_reusable(job, context)
  let (count, steps, bytes) = expansion_budget(tx, run)
  let executable = children.filter(job => {
    job.dynamic_matrix is None && job.reusable_call is None
  })
  guard count + executable.length() <= 256 &&
    steps + executable.fold(init=0, (count, job) => count + job.steps.length()) <=
    4096 &&
    bytes +
    children.fold(init=0, (count, job) => {
      count + @utf8.encode(ToJson::to_json(job).stringify()).length()
    }) <=
    1048576 else {
    raise @domain.BadRequest(
      message="reusable expansion exceeds workflow job, step or snapshot budget",
    )
  }
  persist_expanded_jobs(tx, run, job, children)
  ignore(
    tx.execute(
      "INSERT INTO pipeline_call_expansion(job_id,inputs_json) VALUES(?,?)",
      params=[job_id, ToJson::to_json(inputs).stringify()],
    ),
  )
  reuse_expanded_jobs(tx, run.id)
}

///|
fn complete_call_barrier(
  tx : @database.DbTransaction,
  run : Run,
  job_id : Int64,
  job : @workflow.Job,
) -> Unit raise {
  let expansion = tx.query_one(
    "SELECT inputs_json,cancel_requested FROM pipeline_call_expansion WHERE job_id=?",
    params=[job_id],
  )
  let child_context = job_needs_context(
    tx,
    run.id,
    @workflow.call_output_dependencies(job),
  )
  let mut conclusion = if (expansion.get_name("cancel_requested") : Bool) {
    "cancelled"
  } else if child_context
    .values()
    .any(value => value is { "result": "failure", .. }) {
    "failure"
  } else if child_context
    .values()
    .any(value => value is { "result": "cancelled", .. }) {
    "cancelled"
  } else {
    "success"
  }
  if conclusion != "cancelled" {
    try {
      let inputs : Map[String, Json] = @json.from_json(
        @json.parse((expansion.get_name("inputs_json") : String)),
      )
      let values = @workflow.reusable_outputs(
        job,
        child_context,
        inputs,
        run_job_github(tx, run),
      )
      let outputs = filter_aggregate_outputs(tx, run.public_id, values)
      if !outputs.is_empty() {
        let text = ToJson::to_json(outputs).stringify()
        guard stored_output_bytes(tx, run.id) +
          @utf8.encode(text).length().to_int64() <=
          262144L else {
          raise @domain.BadRequest(message="run job outputs exceed 256 KiB")
        }
        ignore(
          tx.execute(
            "INSERT INTO pipeline_call_output(job_id,outputs_json) VALUES(?,?)",
            params=[job_id, text],
          ),
        )
      }
    } catch {
      @workflow.InvalidWorkflow(message) | @domain.BadRequest(message~) => {
        conclusion = "failure"
        ignore(
          tx.execute("UPDATE pipeline_job SET scheduling_error=? WHERE id=?", params=[
            message, job_id,
          ]),
        )
      }
      err => raise err
    }
  }
  ignore(
    tx.execute(
      "UPDATE pipeline_job SET status='completed',conclusion=? WHERE id=? AND status='waiting'",
      params=[conclusion, job_id],
    ),
  )
}

///|
fn cancel_reusable_call(
  tx : @database.DbTransaction,
  run_id : Int64,
  job_id : Int64,
  key : String,
) -> Unit raise {
  let prefix = key + "/"
  ignore(
    tx.execute(
      "UPDATE pipeline_call_expansion SET cancel_requested=1 WHERE job_id IN (SELECT id FROM pipeline_job WHERE run_id=? AND (id=? OR substr(job_key,1,length(?))=?))",
      params=[run_id, job_id, prefix, prefix],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job SET status='completed',conclusion='cancelled' WHERE run_id=? AND (id=? OR substr(job_key,1,length(?))=?) AND status IN ('waiting','queued') AND NOT EXISTS (SELECT 1 FROM pipeline_call_expansion e WHERE e.job_id=pipeline_job.id)",
      params=[run_id, job_id, prefix, prefix],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job_attempt SET cancel_at_ms=COALESCE(cancel_at_ms,CAST(strftime('%s','now') AS INTEGER)*1000) WHERE status<>'completed' AND job_id IN (SELECT id FROM pipeline_job WHERE run_id=? AND (id=? OR substr(job_key,1,length(?))=?))",
      params=[run_id, job_id, prefix, prefix],
    ),
  )
}
