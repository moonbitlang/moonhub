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
  sequence : Int64
  step_id : String
  stream : String
  text : String
} derive(ToJson, FromJson)

///|
pub(all) struct CompleteRequest {
  version : Int
  conclusion : String
  last_log_sequence : Int64
} derive(ToJson, FromJson)

///|
pub(all) struct LeaseState {
  version : Int
  execution_id : String
  attempt_id : Int64
  state : String
  lease_until_ms : Int64
  server_time_ms : Int64
  deadline_ms : Int64
  cancel_requested : Bool
  log_sequence : Int64
  conclusion : String
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct Assignment {
  version : Int
  attempt_id : Int64
  run_id : Int64
  job_id : Int64
  repository : String
  commit_sha : String
  lease_until_ms : Int64
  server_time_ms : Int64
  state : String
  job : JobPlan
} derive(Debug, ToJson, FromJson)

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
  id : Int64
  step_id : String
  stream : String
  text : String
} derive(Debug, ToJson, FromJson)
