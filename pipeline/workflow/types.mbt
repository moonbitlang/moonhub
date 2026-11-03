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
pub let format_version : Int32 = 1

///|
#derive(Debug, ToJson, FromJson)
pub struct Workflow {
  name : String
  jobs : Array[Job]
}

///|
#derive(Debug, ToJson, FromJson)
pub struct Job {
  id : String
  name : String
  needs : Array[String]
  runs_on : Array[String]
  timeout_minutes : Int32
  steps : Array[Step]
}

///|
#derive(Debug, ToJson)
pub struct Step {
  id : String
  name : String
  run : String
  uses : String?
  moonbit_version : String?
  shell : String?
  working_directory : String
  env : Map[String, String]
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
