///|
#derive(Eq, Debug)
pub enum RunState {
  Queued
  Running
  Completed
}

///|
#derive(Eq, Debug)
pub enum JobState {
  Waiting
  Queued
  Leased
  Running
  Completed
}

///|
#derive(Eq, Debug)
pub enum Conclusion {
  Success
  Failure
  Cancelled
  TimedOut
  Lost
  Skipped
}

///|
#derive(Debug)
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
  definition_version : Int32
  workflow_source : String
  definition : @workflow.Workflow
  context : @workflow.RunContext?
  state : RunState
  conclusion : Conclusion?
  created_at : String
}

///|
#derive(Debug)
pub struct JobRun {
  id : Int64
  run_id : Int64
  job_key : String
  state : JobState
  conclusion : Conclusion?
  attempt_id : Int64?
}

///|
pub struct MergeCheckContext {
  number : Int64
  version : Int64
  source_sha : String
  target_sha : String
}

///|
pub fn merge_check_context(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
) -> MergeCheckContext? raise {
  let run = get_run(pool, actor, repo, number)
  pool.with_client(client => {
    client
    .query_opt(
      "SELECT m.number, c.version, v.source_sha, v.target_sha FROM pipeline_run p JOIN merge_check c ON c.id = p.merge_check_id JOIN merge_request m ON m.id = c.merge_request_id JOIN merge_revision v ON v.merge_request_id = c.merge_request_id AND v.version = c.version WHERE p.id = ? AND m.repository_id = p.repository_id",
      params=[run.id],
    )
    .map(row => {
      number: row.get_name("number"),
      version: row.get_name("version"),
      source_sha: row.get_name("source_sha"),
      target_sha: row.get_name("target_sha"),
    })
  })
}

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
  guard [1L, 2L, 3L, 4L, 5L, @workflow.format_version.to_int64()].contains(
    version,
  ) else {
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
    context: (row.get_name("context_json") : String?).map(text => {
      @json.from_json(@json.parse(text))
    }),
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
pub fn list_runs(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  page~ : Int64 = 1L,
  status~ : String = "",
  branch~ : String = "",
  workflow~ : String = "",
) -> Array[Run] raise {
  guard page > 0L &&
    page <= 100000L &&
    [
      "", "queued", "running", "success", "failure", "cancelled", "timed_out", "lost",
      "skipped",
    ].contains(status) else {
    raise @domain.BadRequest(message="invalid pipeline filter or page")
  }
  let scope = @repository.repository_scope(pool, actor, repo)
  pool.with_client(client => {
    client
    .query_all(
      "SELECT * FROM pipeline_run WHERE repository_id = ? AND (? = '' OR status = ? OR conclusion = ?) AND (? = '' OR source_branch = ?) AND (? = '' OR workflow_path = ?) ORDER BY number DESC LIMIT 51 OFFSET ?",
      params=[
        scope.id,
        status,
        status,
        status,
        branch,
        branch,
        workflow,
        workflow,
        (page - 1L) * 50L,
      ],
    )
    .map(row => Run::from_row(row))
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
    .query_all(
      "SELECT j.*, (SELECT a.id FROM pipeline_job_attempt a WHERE a.job_id = j.id ORDER BY a.number DESC LIMIT 1) AS attempt_id FROM pipeline_job j WHERE j.run_id = ? ORDER BY j.ordinal",
      params=[run.id],
    )
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
        attempt_id: row.get_name("attempt_id"),
      }
    })
  })
}
