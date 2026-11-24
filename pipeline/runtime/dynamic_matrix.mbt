///|
fn saved_job(
  tx : @database.DbTransaction,
  run : Run,
  job_id : Int64,
  key : String,
) -> @workflow.Job raise {
  if tx.query_opt(
      "SELECT definition_json FROM pipeline_job_definition WHERE job_id=?",
      params=[job_id],
    )
    is Some(row) {
    return @json.from_json(
      @json.parse((row.get_name("definition_json") : String)),
    )
  }
  guard run.definition.jobs.iter().find_first(job => job.id == key) is Some(job) else {
    raise InvalidRecord
  }
  job
}

///|
fn expand_run_matrix(
  tx : @database.DbTransaction,
  run : Run,
  job_id : Int64,
  job : @workflow.Job,
  context : Map[String, Json],
) -> Unit raise {
  let (count, steps, bytes) = expansion_budget(tx, run)
  let (matrix, children) = @workflow.expand_dynamic_matrix(
    job,
    context,
    remaining_jobs=256 - count,
    remaining_steps=4096 - steps,
    remaining_bytes=1048576 - bytes,
  )
  persist_expanded_jobs(tx, run, job, children)
  ignore(
    tx.execute(
      "INSERT INTO pipeline_matrix_expansion(job_id,matrix_json) VALUES(?,?)",
      params=[job_id, matrix.stringify()],
    ),
  )
  reuse_expanded_jobs(tx, run.id)
}

///|
fn complete_matrix_barrier(
  tx : @database.DbTransaction,
  run : Run,
  job_id : Int64,
  key : String,
) -> Unit raise {
  let rows = tx.query_all(
    "SELECT conclusion,actual_conclusion FROM pipeline_job WHERE run_id=? AND matrix_group=?",
    params=[run.id, key],
  )
  let conclusion = if rows.any(row => {
      ["failure", "timed_out", "lost"].contains(
        (row.get_name("conclusion") : String?).unwrap_or(""),
      )
    }) {
    "failure"
  } else if rows.any(row => {
      (row.get_name("conclusion") : String?) == Some("cancelled")
    }) {
    "cancelled"
  } else {
    "success"
  }
  ignore(
    tx.execute(
      "UPDATE pipeline_job SET status='completed',conclusion=? WHERE id=? AND status='waiting'",
      params=[conclusion, job_id],
    ),
  )
}

///|
fn expansion_budget(
  tx : @database.DbTransaction,
  run : Run,
) -> (Int32, Int32, Int32) raise {
  let persisted = tx.query_all(
    "SELECT d.definition_json FROM pipeline_job_definition d JOIN pipeline_job j ON j.id=d.job_id WHERE j.run_id=?",
    params=[run.id],
  )
  let mut count = run.definition.jobs
    .filter(job => job.dynamic_matrix is None && job.reusable_call is None)
    .length()
  let mut steps = run.definition.jobs.fold(init=0, (count, job) => {
    count +
    (if job.dynamic_matrix is None && job.reusable_call is None {
      job.steps.length()
    } else {
      0
    })
  })
  let mut bytes = @utf8.encode(ToJson::to_json(run.definition).stringify()).length()
  for row in persisted {
    let text : String = row.get_name("definition_json")
    let saved : @workflow.Job = @json.from_json(@json.parse(text))
    if saved.dynamic_matrix is None && saved.reusable_call is None {
      count += 1
      steps += saved.steps.length()
    }
    bytes += @utf8.encode(text).length()
  }
  (count, steps, bytes)
}

///|
fn persist_expanded_jobs(
  tx : @database.DbTransaction,
  run : Run,
  job : @workflow.Job,
  children : Array[@workflow.Job],
) -> Unit raise {
  // Validate all generated definitions and budgets before writing any child.
  validate_secret_policy(
    tx,
    run.repository_id,
    run.source_branch,
    run.workflow_path,
    run.context,
    children,
  )
  let ordinal : Int64 = tx
    .query_one(
      "SELECT COALESCE(MAX(ordinal),0)+1 AS ordinal FROM pipeline_job WHERE run_id=?",
      params=[run.id],
    )
    .get_name("ordinal")
  for index, child in children {
    let id : Int64 = tx
      .query_one(
        "INSERT INTO pipeline_job(run_id,job_key,ordinal,status,matrix_group,max_parallel,matrix_fail_fast) VALUES(?,?,?,'waiting',?,?,?) RETURNING id",
        params=[
          run.id,
          child.id,
          ordinal + index.to_int64(),
          child.matrix_group,
          child.max_parallel.to_int64(),
          child.fail_fast,
        ],
      )
      .get_name("id")
    ignore(
      tx.execute(
        "INSERT INTO pipeline_job_definition(job_id,definition_json) VALUES(?,?)",
        params=[id, ToJson::to_json(child).stringify()],
      ),
    )
    for label in child.runs_on {
      ignore(
        tx.execute("INSERT INTO pipeline_job_label(job_id,label) VALUES(?,?)", params=[
          id, label,
        ]),
      )
    }
    if !child.runner_group.is_empty() {
      ignore(
        tx.execute(
          "INSERT INTO pipeline_job_runner_group(job_id,group_name) VALUES(?,?)",
          params=[id, child.runner_group],
        ),
      )
    }
  }
  for child in children {
    let needs = child.needs.copy()
    for need in job.needs {
      if !needs.contains(need) {
        needs.push(need)
      }
    }
    for need in needs {
      ignore(
        tx.execute(
          "INSERT INTO pipeline_job_need(run_id,job_key,needs_job_key) VALUES(?,?,?)",
          params=[run.id, child.id, need],
        ),
      )
    }
    ignore(
      tx.execute(
        "INSERT INTO pipeline_job_need(run_id,job_key,needs_job_key) VALUES(?,?,?)",
        params=[run.id, job.id, child.id],
      ),
    )
  }
}

///|
fn reuse_expanded_jobs(
  tx : @database.DbTransaction,
  run_id : Int64,
) -> Unit raise {
  if tx.query_opt(
      "SELECT source_run_id FROM pipeline_run_reuse_source WHERE run_id=?",
      params=[run_id],
    )
    is Some(row) {
    reuse_successful_jobs(tx, run_id, row.get_name("source_run_id"))
  }
}
