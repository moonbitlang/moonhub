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
pub let format_version : Int32 = 2

///|
#derive(Debug, ToJson, FromJson)
pub struct Workflow {
  name : String
  jobs : Array[Job]
}

///|
#derive(Debug, ToJson)
pub struct Job {
  id : String
  name : String
  needs : Array[String]
  runs_on : Array[String]
  contents_read : Bool
  timeout_minutes : Int32
  steps : Array[Step]
}

///|
pub impl @json.FromJson for Job with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "invalid job"))
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
    needs: @json.from_json(
      fields.get("needs").unwrap_or(Json::null()),
      path=path.add_key("needs"),
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
