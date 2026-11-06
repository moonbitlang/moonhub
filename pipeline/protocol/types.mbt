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
// V5 executes downloaded action metadata, inputs and file commands.
pub let remote_assignment_version : Int32 = 5

///|
// V6 carries typed matrix/strategy contexts. Old runners reject rather than
// silently execute empty context values during a rolling upgrade.
pub let scheduling_assignment_version : Int32 = 6

///|
// V7 carries declared output templates and completed direct-needs contexts.
pub let dataflow_assignment_version : Int32 = 7

///|
// V8 carries immutable workflow dispatch inputs and its event payload.
pub let dispatch_assignment_version : Int32 = 8

///|
// V9 carries the immutable repository configuration variables snapshot.
pub let variable_assignment_version : Int32 = 9

///|
pub fn action_runtime_version(version : Int32) -> Bool {
  [
    remote_assignment_version, scheduling_assignment_version, dataflow_assignment_version,
    dispatch_assignment_version, variable_assignment_version,
  ].contains(version)
}

///|
#derive(ToJson, FromJson)
pub(all) struct SecretRequest {
  version : Int32
  execution_id : String
  step_id : String
}

///|
#derive(ToJson, FromJson)
pub(all) struct SecretResponse {
  version : Int32
  env : Map[String, String]
}

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
#derive(ToJson, FromJson)
pub(all) struct ClaimRequest {
  runner_os : String?
  version : Int32
  request_id : String
  attempt_token : String
}

///|
#derive(ToJson, FromJson)
pub(all) struct VersionRequest {
  version : Int32
}

///|
#derive(ToJson, FromJson)
pub(all) struct StartRequest {
  version : Int32
  execution_id : String
}

///|
#derive(Debug, ToJson, FromJson)
pub(all) struct StepRequest {
  version : Int32
  step_id : String
  state : String
  exit_code : Int32
}

///|
#derive(Debug, ToJson, FromJson)
pub(all) struct StepState {
  step_id : String
  state : String
  exit_code : Int32
}

///|
#derive(ToJson, FromJson)
pub(all) struct LogRequest {
  version : Int32
  sequence : String
  step_id : String
  stream : String
  text : String
}

///|
#derive(ToJson)
pub(all) struct CompleteRequest {
  version : Int32
  conclusion : String
  last_log_sequence : String
  outputs : Map[String, String]
}

///|
#derive(Debug, ToJson, FromJson)
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
}

///|
#derive(Debug, ToJson, FromJson)
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
}

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
#derive(Debug, ToJson)
pub(all) struct JobPlan {
  variables : Map[String, String]
  dispatch_inputs : Map[String, Json]
  event : Map[String, Json]
  outputs : Map[String, String]
  needs : Map[String, Json]
  context : Map[String, String]
  contents_read : Bool
  matrix : Map[String, Json]
  strategy : Map[String, Json]
  id : String
  name : String
  runs_on : Array[String]
  timeout_minutes : Int32
  steps : Array[StepPlan]
}

///|
pub impl @json.FromJson for JobPlan with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "invalid job plan"))
  }
  {
    variables: @json.from_json(
      fields.get("variables").unwrap_or(({} : Json)),
      path=path.add_key("variables"),
    ),
    dispatch_inputs: @json.from_json(
      fields.get("dispatch_inputs").unwrap_or(({} : Json)),
      path=path.add_key("dispatch_inputs"),
    ),
    event: @json.from_json(
      fields.get("event").unwrap_or(({} : Json)),
      path=path.add_key("event"),
    ),
    outputs: @json.from_json(
      fields.get("outputs").unwrap_or(({} : Json)),
      path=path.add_key("outputs"),
    ),
    needs: @json.from_json(
      fields.get("needs").unwrap_or(({} : Json)),
      path=path.add_key("needs"),
    ),
    strategy: @json.from_json(
      fields.get("strategy").unwrap_or(({} : Json)),
      path=path.add_key("strategy"),
    ),
    matrix: @json.from_json(
      fields.get("matrix").unwrap_or(({} : Json)),
      path=path.add_key("matrix"),
    ),
    contents_read: @json.from_json(
      fields.get("contents_read").unwrap_or(Json::boolean(true)),
      path=path.add_key("contents_read"),
    ),
    context: @json.from_json(
      fields.get("context").unwrap_or(({} : Json)),
      path=path.add_key("context"),
    ),
    id: @json.from_json(
      fields.get("id").unwrap_or(Json::null()),
      path=path.add_key("id"),
    ),
    name: @json.from_json(
      fields.get("name").unwrap_or(Json::null()),
      path=path.add_key("name"),
    ),
    runs_on: @json.from_json(
      fields.get("runs_on").unwrap_or(Json::null()),
      path=path.add_key("runs_on"),
    ),
    timeout_minutes: @json.from_json(
      fields.get("timeout_minutes").unwrap_or(Json::null()),
      path=path.add_key("timeout_minutes"),
    ),
    steps: @json.from_json(
      fields.get("steps").unwrap_or(Json::null()),
      path=path.add_key("steps"),
    ),
  }
}

///|
#derive(Debug, ToJson)
pub(all) struct StepPlan {
  id : String
  name : String
  run : String
  uses : String
  moonbit_version : String
  remote : Bool
  inputs : Map[String, String]
  templates : Map[String, String]
  shell : String
  working_directory : String
  env : Map[String, String]
  env_overrides : Array[String]
  secret_env : Map[String, String]
  timeout_minutes : Int32
}

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
    remote: match json {
      Object(fields) =>
        @json.from_json(
          fields.get("remote").unwrap_or(Json::boolean(false)),
          path=path.add_key("remote"),
        )
      _ => false
    },
    inputs: match json {
      Object(fields) =>
        @json.from_json(
          fields.get("inputs").unwrap_or(({} : Json)),
          path=path.add_key("inputs"),
        )
      _ => Map([])
    },
    templates: match json {
      Object(fields) =>
        @json.from_json(
          fields.get("templates").unwrap_or(({} : Json)),
          path=path.add_key("templates"),
        )
      _ => Map([])
    },
    moonbit_version,
    shell: @json.from_json(shell, path=path.add_key("shell")),
    working_directory: @json.from_json(
      directory,
      path=path.add_key("working_directory"),
    ),
    env: @json.from_json(env, path=path.add_key("env")),
    env_overrides: match json {
      Object(fields) =>
        @json.from_json(
          fields.get("env_overrides").unwrap_or(Json::array([])),
          path=path.add_key("env_overrides"),
        )
      _ => []
    },
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
#derive(Debug, ToJson, FromJson)
pub(all) struct LogChunk {
  id : String
  step_id : String
  stream : String
  text : String
}

///|
#derive(ToJson, FromJson)
pub(all) struct ArtifactRuntimeRequest {
  version : Int32
  execution_id : String
  origin : String
}

///|
#derive(ToJson, FromJson)
pub(all) struct ArtifactRuntime {
  token : String
  results_url : String
  expires_ms : String
}

///|
pub impl @json.FromJson for CompleteRequest with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "invalid completion"))
  }
  {
    version: @json.from_json(
      fields.get("version").unwrap_or(Json::null()),
      path=path.add_key("version"),
    ),
    conclusion: @json.from_json(
      fields.get("conclusion").unwrap_or(Json::null()),
      path=path.add_key("conclusion"),
    ),
    last_log_sequence: @json.from_json(
      fields.get("last_log_sequence").unwrap_or(Json::null()),
      path=path.add_key("last_log_sequence"),
    ),
    outputs: @json.from_json(
      fields.get("outputs").unwrap_or(({} : Json)),
      path=path.add_key("outputs"),
    ),
  }
}
