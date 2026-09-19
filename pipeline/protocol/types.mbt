///|
pub let version : Int = 1

///|
pub let lease_ms : Int64 = 60000L

///|
pub let cancel_grace_ms : Int64 = 15000L

///|
pub let max_log_chunk_bytes : Int = 8192

///|
pub let max_log_bytes : Int64 = 1048576L

///|
pub let max_log_chunks : Int64 = 4096L

///|
pub let max_source_bytes : Int64 = 67108864L

///|
// Wire integers are canonical nonnegative decimal strings, not JSON numbers.
pub fn parse_decimal(value : String) -> Int64? {
  guard !value.is_empty() &&
    value.length() <= 19 &&
    value.iter().all(ch => ch.is_ascii_digit()) &&
    (value == "0" || !value.has_prefix("0")) else {
    return None
  }
  Some(@string.parse_int64(value) catch { _ => return None })
}

///|
pub(all) struct ClaimRequest {
  version : Int
  request_id : String
  attempt_token : String
} derive(ToJson, FromJson)

///|
pub(all) struct VersionRequest {
  version : Int
} derive(ToJson, FromJson)

///|
pub(all) struct StartRequest {
  version : Int
  execution_id : String
} derive(ToJson, FromJson)

///|
pub(all) struct StepRequest {
  version : Int
  step_id : String
  state : String
  exit_code : Int
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct StepState {
  step_id : String
  state : String
  exit_code : Int
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct LogRequest {
  version : Int
  sequence : String
  step_id : String
  stream : String
  text : String
} derive(ToJson, FromJson)

///|
pub(all) struct CompleteRequest {
  version : Int
  conclusion : String
  last_log_sequence : String
} derive(ToJson, FromJson)

///|
pub(all) struct LeaseState {
  version : Int
  execution_id : String
  attempt_id : String
  state : String
  lease_until_ms : String
  server_time_ms : String
  deadline_ms : String
  cancel_requested : Bool
  log_sequence : String
  conclusion : String
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Assignment {
  version : Int
  attempt_id : String
  run_id : String
  job_id : String
  repository : String
  commit_sha : String
  lease_until_ms : String
  server_time_ms : String
  state : String
  job : JobPlan
} derive(Debug, ToJson, FromJson)

///|
pub fn Assignment::has_valid_numbers(self : Assignment) -> Bool {
  for id in [self.attempt_id, self.run_id, self.job_id] {
    guard parse_decimal(id) is Some(id) && id > 0L else { return false }
  }
  match
    (parse_decimal(self.lease_until_ms), parse_decimal(self.server_time_ms)) {
    (Some(until), Some(now)) => until >= now && until - now <= lease_ms
    _ => false
  }
}

///|
pub(all) struct JobPlan {
  id : String
  name : String
  runs_on : Array[String]
  timeout_minutes : Int
  steps : Array[StepPlan]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct StepPlan {
  id : String
  name : String
  run : String
  shell : String
  working_directory : String
  env : Map[String, String]
  timeout_minutes : Int
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct LogChunk {
  id : String
  step_id : String
  stream : String
  text : String
} derive(Debug, ToJson, FromJson)
