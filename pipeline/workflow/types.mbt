// Workflow/job/step mapping is adapted from mizchi/actrun v0.30.1.
// See THIRD_PARTY.md for provenance and the changes to its contract.

///|
#derive(Debug)
pub suberror InvalidWorkflow {
  InvalidWorkflow(String)
}

///|
pub let max_source_bytes : Int32 = 65536

///|
pub let format_version : Int32 = 9

///|
#derive(Debug, ToJson)
pub struct Workflow {
  run_name : String
  name : String
  concurrency : Concurrency?
  jobs : Array[Job]
}

///|
#derive(Debug, ToJson)
pub struct Concurrency {
  group : String
  cancel_in_progress : String
  queue_max : Bool
}

///|
pub impl @json.FromJson for Concurrency with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "invalid concurrency"))
  }
  {
    group: @json.from_json(
      fields.get("group").unwrap_or(Json::null()),
      path=path.add_key("group"),
    ),
    cancel_in_progress: @json.from_json(
      fields.get("cancel_in_progress").unwrap_or(Json::string("false")),
      path=path.add_key("cancel_in_progress"),
    ),
    queue_max: @json.from_json(
      fields.get("queue_max").unwrap_or(Json::boolean(false)),
      path=path.add_key("queue_max"),
    ),
  }
}

///|
#derive(Debug, ToJson, FromJson)
pub struct DynamicMatrix {
  expression : String
  source : Json
  env : Map[String, String]
  shell : String?
  directory : String?
  contents_read : Bool
  id_token_write : Bool
  api_permissions : Int32
}

///|
#derive(Debug, ToJson, FromJson)
pub struct ReusableCall {
  path : String
  source : String
  definition : Workflow
  inputs : Array[DispatchInput]
  supplied : Map[String, Json]
  outputs : Map[String, String]
}

///|
pub impl @json.FromJson for Workflow with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "invalid workflow"))
  }
  {
    run_name: @json.from_json(
      fields.get("run_name").unwrap_or(Json::string("")),
      path=path.add_key("run_name"),
    ),
    name: @json.from_json(
      fields.get("name").unwrap_or(Json::null()),
      path=path.add_key("name"),
    ),
    jobs: @json.from_json(
      fields.get("jobs").unwrap_or(Json::null()),
      path=path.add_key("jobs"),
    ),
    concurrency: match fields.get("concurrency") {
      None | Some(Null) => None
      Some(value) =>
        Some(@json.from_json(value, path=path.add_key("concurrency")))
    },
  }
}

///|
#derive(Debug, ToJson)
pub struct Job {
  compatibility_runtime : Bool
  continue_on_error : String
  concurrency : Concurrency?
  dynamic_matrix : DynamicMatrix?
  reusable_call : ReusableCall?
  call_inputs : Map[String, Json]?
  context_prefix : String
  deployment_environment : String
  deployment_url : String
  containers : @actions.ContainerPlan?
  id : String
  name : String
  needs : Array[String]
  condition : String
  outputs : Map[String, String]
  runs_on : Array[String]
  runner_group : String
  contents_read : Bool
  id_token_write : Bool
  api_permissions : Int32
  matrix : Map[String, Json]
  strategy : Map[String, Json]
  matrix_group : String
  fail_fast : Bool
  max_parallel : Int32
  timeout_minutes : Int32
  steps : Array[Step]
}

///|
pub impl @json.FromJson for Job with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "invalid job"))
  }
  {
    continue_on_error: @json.from_json(
      fields.get("continue_on_error").unwrap_or(Json::string("false")),
      path=path.add_key("continue_on_error"),
    ),
    concurrency: match fields.get("concurrency") {
      None | Some(Null) => None
      Some(value) =>
        Some(@json.from_json(value, path=path.add_key("concurrency")))
    },
    reusable_call: match fields.get("reusable_call") {
      None | Some(Null) => None
      Some(value) =>
        Some(@json.from_json(value, path=path.add_key("reusable_call")))
    },
    call_inputs: match fields.get("call_inputs") {
      None | Some(Null) => None
      Some(value) =>
        Some(@json.from_json(value, path=path.add_key("call_inputs")))
    },
    containers: match fields.get("containers") {
      None | Some(Null) => None
      Some(value) =>
        Some(@json.from_json(value, path=path.add_key("containers")))
    },
    deployment_environment: @json.from_json(
      fields.get("deployment_environment").unwrap_or(Json::string("")),
      path=path.add_key("deployment_environment"),
    ),
    deployment_url: @json.from_json(
      fields.get("deployment_url").unwrap_or(Json::string("")),
      path=path.add_key("deployment_url"),
    ),
    context_prefix: @json.from_json(
      fields.get("context_prefix").unwrap_or(Json::string("")),
      path=path.add_key("context_prefix"),
    ),
    dynamic_matrix: match fields.get("dynamic_matrix") {
      None | Some(Null) => None
      Some(value) =>
        Some(@json.from_json(value, path=path.add_key("dynamic_matrix")))
    },
    compatibility_runtime: @json.from_json(
      fields.get("compatibility_runtime").unwrap_or(Json::boolean(false)),
      path=path.add_key("compatibility_runtime"),
    ),
    id: @json.from_json(
      fields.get("id").unwrap_or(Json::null()),
      path=path.add_key("id"),
    ),
    name: @json.from_json(
      fields.get("name").unwrap_or(Json::null()),
      path=path.add_key("name"),
    ),
    needs: @json.from_json(
      fields.get("needs").unwrap_or(Json::null()),
      path=path.add_key("needs"),
    ),
    condition: @json.from_json(
      fields.get("condition").unwrap_or(Json::string("success()")),
      path=path.add_key("condition"),
    ),
    outputs: @json.from_json(
      fields.get("outputs").unwrap_or(({} : Json)),
      path=path.add_key("outputs"),
    ),
    runs_on: @json.from_json(
      fields.get("runs_on").unwrap_or(Json::null()),
      path=path.add_key("runs_on"),
    ),
    runner_group: @json.from_json(
      fields.get("runner_group").unwrap_or(Json::string("")),
      path=path.add_key("runner_group"),
    ),
    timeout_minutes: @json.from_json(
      fields.get("timeout_minutes").unwrap_or(Json::null()),
      path=path.add_key("timeout_minutes"),
    ),
    steps: @json.from_json(
      fields.get("steps").unwrap_or(Json::null()),
      path=path.add_key("steps"),
    ),
    matrix: @json.from_json(
      fields.get("matrix").unwrap_or(({} : Json)),
      path=path.add_key("matrix"),
    ),
    strategy: @json.from_json(
      fields.get("strategy").unwrap_or(({} : Json)),
      path=path.add_key("strategy"),
    ),
    matrix_group: @json.from_json(
      fields.get("matrix_group").unwrap_or(Json::string("")),
      path=path.add_key("matrix_group"),
    ),
    fail_fast: @json.from_json(
      fields.get("fail_fast").unwrap_or(Json::boolean(false)),
      path=path.add_key("fail_fast"),
    ),
    max_parallel: @json.from_json(
      fields.get("max_parallel").unwrap_or(ToJson::to_json(256)),
      path=path.add_key("max_parallel"),
    ),
    api_permissions: @json.from_json(
      fields.get("api_permissions").unwrap_or(Json::number(0)),
      path=path.add_key("api_permissions"),
    ),
    id_token_write: @json.from_json(
      fields.get("id_token_write").unwrap_or(Json::boolean(false)),
      path=path.add_key("id_token_write"),
    ),
    contents_read: @json.from_json(
      fields.get("contents_read").unwrap_or(Json::boolean(true)),
      path=path.add_key("contents_read"),
    ),
  }
}

///|
#derive(Debug, ToJson)
pub struct Step {
  id : String
  name : String
  run : String
  uses : String?
  moonbit_version : String?
  remote : Bool
  inputs : Map[String, String]
  templates : Map[String, String]
  shell : String?
  working_directory : String
  env : Map[String, String]
  env_overrides : Array[String]
  secret_env : Map[String, String]
  timeout_minutes : Int32?
}

///|
pub impl @json.FromJson for Step with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "invalid workflow step"))
  }
  {
    id: @json.from_json(
      fields.get("id").unwrap_or(Json::null()),
      path=path.add_key("id"),
    ),
    name: @json.from_json(
      fields.get("name").unwrap_or(Json::null()),
      path=path.add_key("name"),
    ),
    run: @json.from_json(
      fields.get("run").unwrap_or(Json::null()),
      path=path.add_key("run"),
    ),
    uses: match fields.get("uses") {
      None | Some(Null) => None
      Some(value) => Some(@json.from_json(value, path=path.add_key("uses")))
    },
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
    moonbit_version: match fields.get("moonbit_version") {
      None | Some(Null) => None
      Some(value) =>
        Some(@json.from_json(value, path=path.add_key("moonbit_version")))
    },
    shell: match fields.get("shell") {
      None | Some(Null) => None
      Some(value) => Some(@json.from_json(value, path=path.add_key("shell")))
    },
    working_directory: @json.from_json(
      fields.get("working_directory").unwrap_or(Json::null()),
      path=path.add_key("working_directory"),
    ),
    env: @json.from_json(
      fields.get("env").unwrap_or(Json::null()),
      path=path.add_key("env"),
    ),
    env_overrides: @json.from_json(
      fields.get("env_overrides").unwrap_or(Json::array([])),
      path=path.add_key("env_overrides"),
    ),
    secret_env: @json.from_json(
      fields.get("secret_env").unwrap_or(({} : Json)),
      path=path.add_key("secret_env"),
    ),
    timeout_minutes: match fields.get("timeout_minutes") {
      None | Some(Null) => None
      Some(value) =>
        Some(@json.from_json(value, path=path.add_key("timeout_minutes")))
    },
  }
}

///|
priv struct RunDefaults {
  shell : String?
  working_directory : String?
}
