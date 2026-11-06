///|
fn run_job_github(
  tx : @database.DbTransaction,
  run : Run,
) -> Map[String, Json] raise {
  let number : Int64? = tx
    .query_one(
      "SELECT m.number FROM pipeline_run r LEFT JOIN merge_check c ON c.id=r.merge_check_id LEFT JOIN merge_request m ON m.id=c.merge_request_id WHERE r.id=?",
      params=[run.id],
    )
    .get_name("number")
  {
    "ref": Json::string(
      number
      .map(n => "refs/pull/" + n.to_string() + "/merge")
      .unwrap_or("refs/heads/" + run.source_branch),
    ),
    "repository": Json::string(
      run.context.map(ctx => ctx.repository).unwrap_or(""),
    ),
    "sha": Json::string(run.commit_sha),
    "workflow": Json::string(run.workflow_name),
    "event_name": Json::string(
      run.context.map(ctx => ctx.event_name).unwrap_or("workflow_dispatch"),
    ),
    "head_ref": Json::string(run.context.map(ctx => ctx.head_ref).unwrap_or("")),
    "base_ref": Json::string(run.context.map(ctx => ctx.base_ref).unwrap_or("")),
    "run_id": Json::string(run.id.to_string()),
  }
}

///|
fn job_needs_context(
  tx : @database.DbTransaction,
  run_id : Int64,
  job : @workflow.Job,
) -> Map[String, Json] raise {
  let result : Map[String, Json] = Map([])
  // Matrix output collisions follow completion order, not matrix ordinal.
  let rows = tx.query_all(
    "SELECT j.job_key,j.matrix_group,j.conclusion,o.outputs_json FROM pipeline_job j LEFT JOIN pipeline_job_output o ON o.job_id=j.id WHERE j.run_id=? AND j.status='completed' ORDER BY COALESCE(o.id,0),j.ordinal",
    params=[run_id],
  )
  for row in rows {
    let key : String = row.get_name("job_key")
    if !job.needs.contains(key) {
      continue
    }
    let group : String = row.get_name("matrix_group")
    let logical = if group.is_empty() { key } else { group }
    let outputs : Map[String, String] = match result.get(logical) {
      Some({ "outputs": value, .. }) => @json.from_json(value)
      _ => Map([])
    }
    if (row.get_name("outputs_json") : String?) is Some(text) {
      let saved : Map[String, String] = @json.from_json(@json.parse(text))
      for name, value in saved {
        outputs[name] = value
      }
    }
    let current : String = (row.get_name("conclusion") : String?).unwrap_or(
      "skipped",
    )
    let current = if ["timed_out", "lost"].contains(current) {
      "failure"
    } else {
      current
    }
    let previous = match result.get(logical) {
      Some({ "result": String(value), .. }) => value
      _ => "success"
    }
    let conclusion = if previous == "failure" || current == "failure" {
      "failure"
    } else if previous == "cancelled" || current == "cancelled" {
      "cancelled"
    } else if previous == "skipped" || current == "skipped" {
      "skipped"
    } else {
      "success"
    }
    result[logical] = {
      "result": conclusion,
      "outputs": ToJson::to_json(outputs),
    }
  }
  result
}

///|
fn publish_job_outputs(
  tx : @database.DbTransaction,
  row : @database.DbRow,
  values : Map[String, String],
  conclusion : String,
) -> Unit raise {
  let job = attempt_job(row)
  guard values.length() <= 100 &&
    @utf8.encode(ToJson::to_json(values).stringify()).length() <= 32768 &&
    values
    .iter()
    .all(entry => {
      job.outputs.contains(entry.0) &&
      !entry.1.contains("\u{0000}") &&
      @utf8.encode(entry.1).length() <= 16384
    }) else {
    raise @domain.BadRequest(message="invalid or oversized job outputs")
  }
  if values.is_empty() || !["success", "failure"].contains(conclusion) {
    return
  }
  guard (row.get_name("definition_version") : Int64) >= 4L &&
    (row.get_name("execution_id") : String?) is Some(_) else {
    raise @domain.BadRequest(
      message="job outputs require an execution-bound dataflow assignment",
    )
  }
  let id : Int64 = row.get_name("id")
  let masks : Array[String] = []
  for
    delivery in tx.query_all(
      "SELECT value FROM pipeline_secret_delivery WHERE attempt_id=?",
      params=[id],
    ) {
    masks.push_iter(secret_masks(delivery.get_name("value")).iter())
  }
  let outputs : Map[String, String] = Map([])
  for key, value in values {
    if !value.is_empty() &&
      !masks.any(mask => !mask.is_empty() && value.contains(mask)) {
      outputs[key] = value
    }
  }
  if outputs.is_empty() {
    return
  }
  let encoded = ToJson::to_json(outputs).stringify()
  let stored : Int64 = tx
    .query_one(
      "SELECT COALESCE(SUM(LENGTH(CAST(o.outputs_json AS BLOB))),0) AS bytes FROM pipeline_job_output o JOIN pipeline_job j ON j.id=o.job_id WHERE j.run_id=?",
      params=[(row.get_name("run_id") : Int64)],
    )
    .get_name("bytes")
  guard stored + @utf8.encode(encoded).length().to_int64() <= 262144L else {
    raise @domain.BadRequest(message="run job outputs exceed 256 KiB")
  }
  ignore(
    tx.execute(
      "INSERT INTO pipeline_job_output(job_id,attempt_id,outputs_json) VALUES(?,?,?)",
      params=[(row.get_name("job_id") : Int64), id, encoded],
    ),
  )
}
