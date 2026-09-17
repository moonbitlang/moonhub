///|
pub enum RunState {
  Queued
  Running
  Completed
} derive(Eq, Debug)

///|
pub enum JobState {
  Waiting
  Queued
  Leased
  Running
  Completed
} derive(Eq, Debug)

///|
pub enum Conclusion {
  Success
  Failure
  Cancelled
  TimedOut
  Lost
  Skipped
} derive(Eq, Debug)

///|
pub struct Run {
  id : Int64
  repository_id : Int64
  number : Int64
  requested_by_user_id : Int64
  workflow_path : String
  workflow_name : String
  source_branch : String
  commit_sha : String
  source_ref : String
  definition_version : Int
  workflow_source : String
  definition : @workflow.Workflow
  state : RunState
  conclusion : Conclusion?
  created_at : String
} derive(Debug)

///|
pub struct JobRun {
  id : Int64
  run_id : Int64
  job_key : String
  state : JobState
  conclusion : Conclusion?
} derive(Debug)

///|
priv suberror InvalidRecord {
  InvalidRecord
}

///|
fn decode_conclusion(value : String?) -> Conclusion? raise {
  match value {
    None => None
    Some("success") => Some(Success)
    Some("failure") => Some(Failure)
    Some("cancelled") => Some(Cancelled)
    Some("timed_out") => Some(TimedOut)
    Some("lost") => Some(Lost)
    Some("skipped") => Some(Skipped)
    _ => raise InvalidRecord
  }
}

///|
fn Run::from_row(row : @database.DbRow) -> Run raise {
  let version : Int64 = row.get_name("definition_version")
  guard version == @workflow.format_version.to_int64() else {
    raise InvalidRecord
  }
  let text : String = row.get_name("definition_json")
  let definition : @workflow.Workflow = @json.from_json(@json.parse(text))
  let status : String = row.get_name("status")
  {
    id: row.get_name("id"),
    repository_id: row.get_name("repository_id"),
    number: row.get_name("number"),
    requested_by_user_id: row.get_name("requested_by_user_id"),
    workflow_path: row.get_name("workflow_path"),
    workflow_name: row.get_name("workflow_name"),
    source_branch: row.get_name("source_branch"),
    commit_sha: row.get_name("commit_sha"),
    source_ref: row.get_name("source_ref"),
    definition_version: version.to_int(),
    workflow_source: row.get_name("workflow_source"),
    definition,
    state: match status {
      "queued" => Queued
      "running" => Running
      "completed" => Completed
      _ => raise InvalidRecord
    },
    conclusion: decode_conclusion(row.get_name("conclusion")),
    created_at: row.get_name("created_at"),
  }
}

///|
pub fn get_run(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
) -> Run raise {
  let scope = @repository.repository_scope(pool, actor, repo)
  pool.with_client(client => {
    let row = client.query_opt(
      "SELECT * FROM pipeline_run WHERE repository_id = ? AND number = ?",
      params=[scope.id, number],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="pipeline run not found")
    }
    Run::from_row(row)
  })
}

///|
pub fn list_jobs(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
) -> Array[JobRun] raise {
  let run = get_run(pool, actor, repo, number)
  pool.with_client(client => {
    client
    .query_all("SELECT * FROM pipeline_job WHERE run_id = ? ORDER BY ordinal", params=[
      run.id,
    ])
    .map(row => {
      let status : String = row.get_name("status")
      {
        id: row.get_name("id"),
        run_id: row.get_name("run_id"),
        job_key: row.get_name("job_key"),
        state: match status {
          "waiting" => Waiting
          "queued" => Queued
          "leased" => Leased
          "running" => Running
          "completed" => Completed
          _ => raise InvalidRecord
        },
        conclusion: decode_conclusion(row.get_name("conclusion")),
      }
    })
  })
}
