///|
pub let version : Int32 = 1

///|
// V2 assignments add built-in action execution. Lease/report API stays V1.
pub let action_assignment_version : Int32 = 2

///|
// V3 assignments add the built-in MoonBit setup action and version input.
pub let toolchain_assignment_version : Int32 = 3

///|
// V4 keeps secret references separate and obtains values from the attempt API.
pub let secret_assignment_version : Int32 = 4

///|
pub(all) struct SecretRequest {
  version : Int32
  execution_id : String
  step_id : String
} derive(ToJson, FromJson)

///|
pub(all) struct SecretResponse {
  version : Int32
  env : Map[String, String]
} derive(ToJson, FromJson)

///|
pub let lease_ms : Int64 = 60000L

///|
pub let cancel_grace_ms : Int64 = 15000L

///|
pub let max_log_chunk_bytes : Int32 = 8192

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
  version : Int32
  request_id : String
  attempt_token : String
} derive(ToJson, FromJson)

///|
pub(all) struct VersionRequest {
  version : Int32
} derive(ToJson, FromJson)

///|
pub(all) struct StartRequest {
  version : Int32
  execution_id : String
} derive(ToJson, FromJson)

///|
pub(all) struct StepRequest {
  version : Int32
  step_id : String
  state : String
  exit_code : Int32
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct StepState {
  step_id : String
  state : String
  exit_code : Int32
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct LogRequest {
  version : Int32
  sequence : String
  step_id : String
  stream : String
  text : String
} derive(ToJson, FromJson)

///|
pub(all) struct CompleteRequest {
  version : Int32
  conclusion : String
  last_log_sequence : String
} derive(ToJson, FromJson)

///|
pub(all) struct LeaseState {
  version : Int32
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
  version : Int32
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
  timeout_minutes : Int32
  steps : Array[StepPlan]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct StepPlan {
  id : String
  name : String
  run : String
  uses : String
  moonbit_version : String
  shell : String
  working_directory : String
  env : Map[String, String]
  secret_env : Map[String, String]
  timeout_minutes : Int32
} derive(Debug, ToJson)

///|
// Legacy assignments have no `uses` or `moonbit_version` fields.
pub impl @json.FromJson for StepPlan with fn from_json(json, path) {
  guard json
    is {
      "id": id,
      "name": name,
      "run": run,
      "shell": shell,
      "working_directory": directory,
      "env": env,
      "timeout_minutes": timeout,
      ..
    } else {
    raise @json.JsonDecodeError((path, "invalid step plan"))
  }
  let uses = match json {
    Object(fields) =>
      match fields.get("uses") {
        None => ""
        Some(value) => @json.from_json(value, path=path.add_key("uses"))
      }
    _ => ""
  }
  let moonbit_version = match json {
    Object(fields) =>
      match fields.get("moonbit_version") {
        None => ""
        Some(value) =>
          @json.from_json(value, path=path.add_key("moonbit_version"))
      }
    _ => ""
  }
  {
    id: @json.from_json(id, path=path.add_key("id")),
    name: @json.from_json(name, path=path.add_key("name")),
    run: @json.from_json(run, path=path.add_key("run")),
    uses,
    moonbit_version,
    shell: @json.from_json(shell, path=path.add_key("shell")),
    working_directory: @json.from_json(
      directory,
      path=path.add_key("working_directory"),
    ),
    env: @json.from_json(env, path=path.add_key("env")),
    secret_env: match json {
      Object(fields) =>
        @json.from_json(
          fields.get("secret_env").unwrap_or(({} : Json)),
          path=path.add_key("secret_env"),
        )
      _ => Map([])
    },
    timeout_minutes: @json.from_json(
      timeout,
      path=path.add_key("timeout_minutes"),
    ),
  }
}

///|
pub(all) struct LogChunk {
  id : String
  step_id : String
  stream : String
  text : String
} derive(Debug, ToJson, FromJson)
