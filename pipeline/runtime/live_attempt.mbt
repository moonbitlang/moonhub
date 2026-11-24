///|
// A validated immutable view. Workflow decoding is deferred until a permission
// or claims consumer actually needs the job definition.
pub struct LiveAttempt {
  id : Int64
  run_id : Int64
  repository_id : Int64
  requested_by_user_id : Int64
  deadline_ms : Int64
  owner_name : String
  repo_name : String
  commit_sha : String
  job_key : String
  definition_version : Int32
  priv job_definition_json : String?
  priv definition_json : String
}

///|
pub fn LiveAttempt::job(self : LiveAttempt) -> @workflow.Job raise {
  guard [1, 2, 3, 4, 5, 6, 7, 8, @workflow.format_version].contains(
    self.definition_version,
  ) else {
    raise InvalidRecord
  }
  if self.job_definition_json is Some(text) {
    return @json.from_json(@json.parse(text))
  }
  let definition : @workflow.Workflow = @json.from_json(
    @json.parse(self.definition_json),
  )
  guard definition.jobs.iter().find_first(job => job.id == self.job_key)
    is Some(job) else {
    raise InvalidRecord
  }
  job
}

///|
pub fn live_attempt(
  tx : @database.DbTransaction,
  attempt : Int64,
  execution : String,
  now : Int64,
) -> LiveAttempt raise {
  let row = tx.query_opt(attempt_select + " WHERE a.id=?", params=[attempt])
  guard row is Some(row) &&
    (row.get_name("status") : String) == "running" &&
    (row.get_name("execution_id") : String?) == Some(execution) &&
    (row.get_name("lease_until_ms") : Int64?) is Some(lease) &&
    lease > now &&
    (row.get_name("deadline_ms") : Int64?) is Some(deadline) &&
    deadline > now &&
    (row.get_name("cancel_at_ms") : Int64?) is None &&
    !(row.get_name("cancel_requested") : Bool) &&
    attempt_authorized(tx, row) else {
    raise @domain.Unauthorized(message="artifact runtime is no longer live")
  }
  {
    id: attempt,
    run_id: row.get_name("run_id"),
    repository_id: row.get_name("repository_id"),
    requested_by_user_id: row.get_name("requested_by_user_id"),
    deadline_ms: row.get_name("deadline_ms"),
    owner_name: row.get_name("owner_name"),
    repo_name: row.get_name("repo_name"),
    commit_sha: row.get_name("commit_sha"),
    job_key: row.get_name("job_key"),
    definition_version: (row.get_name("definition_version") : Int64).to_int(),
    definition_json: row.get_name("definition_json"),
    job_definition_json: row.get_name("job_definition_json"),
  }
}
