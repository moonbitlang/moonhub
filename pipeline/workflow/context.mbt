///|
// Captured once, never rebuilt from current branch/MR state.
#derive(Debug)
pub(all) struct RunContext {
  repository : String
  sha : String
  event_name : String
  head_ref : String
  base_ref : String
  inputs : Map[String, Json]
  variables : Map[String, String]
  release_tag : String?
  event : Map[String, Json]?
}

///|
pub impl ToJson for RunContext with fn to_json(self) {
  let fields : Map[String, Json] = {
    "repository": self.repository,
    "sha": self.sha,
    "event_name": self.event_name,
    "head_ref": self.head_ref,
    "base_ref": self.base_ref,
    "inputs": ToJson::to_json(self.inputs),
    "variables": ToJson::to_json(self.variables),
  }
  if self.event is Some(event) {
    fields["event"] = ToJson::to_json(event)
  }
  if self.release_tag is Some(tag) {
    fields["release_tag"] = Json::string(tag)
  }
  Json::object(fields)
}

///|
pub impl @json.FromJson for RunContext with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "invalid run context"))
  }
  let event_name : String = @json.from_json(
    fields.get("event_name").unwrap_or(Json::null()),
    path=path.add_key("event_name"),
  )
  let release_tag = match fields.get("release_tag") {
    None | Some(Null) => None
    Some(String(tag)) => Some(tag)
    _ =>
      raise @json.JsonDecodeError(
        (path.add_key("release_tag"), "expected a tag string"),
      )
  }
  guard (event_name == "release" && release_tag is Some(tag) && !tag.is_empty()) ||
    (event_name != "release" && release_tag is None) else {
    raise @json.JsonDecodeError((path, "invalid release event context"))
  }
  {
    repository: @json.from_json(
      fields.get("repository").unwrap_or(Json::null()),
      path=path.add_key("repository"),
    ),
    sha: @json.from_json(
      fields.get("sha").unwrap_or(Json::null()),
      path=path.add_key("sha"),
    ),
    event_name,
    head_ref: @json.from_json(
      fields.get("head_ref").unwrap_or(Json::null()),
      path=path.add_key("head_ref"),
    ),
    base_ref: @json.from_json(
      fields.get("base_ref").unwrap_or(Json::null()),
      path=path.add_key("base_ref"),
    ),
    variables: @json.from_json(
      fields.get("variables").unwrap_or(({} : Json)),
      path=path.add_key("variables"),
    ),
    inputs: @json.from_json(
      fields.get("inputs").unwrap_or(({} : Json)),
      path=path.add_key("inputs"),
    ),
    release_tag,
    event: match fields.get("event") {
      None | Some(Null) => None
      Some(value) => Some(@json.from_json(value, path=path.add_key("event")))
    },
  }
}

///|
priv enum EnvSegment {
  Literal(String)
  Field(String)
}

///|
fn env_segments(
  value : String,
  ctx : String,
) -> Array[EnvSegment] raise InvalidWorkflow {
  let result : Array[EnvSegment] = []
  let mut rest = value
  while rest.split_once("${{") is Some((before, expression)) {
    result.push(Literal(before.to_owned()))
    guard expression.split_once("}}") is Some((field, after)) else {
      raise InvalidWorkflow("\{ctx}: unterminated env expression")
    }
    let field = field.trim().to_owned()
    guard [
      "github.repository", "github.sha", "github.event_name", "github.head_ref",
      "github.base_ref",
    ].contains(field) else {
      raise InvalidWorkflow(
        "\{ctx}: unsupported env expressions; only github.repository, github.sha, github.event_name, github.head_ref and github.base_ref are supported",
      )
    }
    result.push(Field(field))
    rest = after.to_owned()
  }
  result.push(Literal(rest))
  result
}

///|
pub fn resolve_context(
  workflow : Workflow,
  context : RunContext,
) -> Workflow raise InvalidWorkflow {
  let jobs = workflow.jobs.map(job => {
    let steps = job.steps.map(step => {
      let env : Map[String, String] = Map([])
      let values = step.env.copy()
      for name, value in step.inputs {
        values["input:" + name] = value
      }
      let inputs : Map[String, String] = Map([])
      for name, value in values {
        let output = StringBuilder()
        for
          segment in env_segments(
            value,
            "jobs.\{job.id}.steps.\{step.id}.env.\{name}",
          ) {
          output.write_string(
            match segment {
              Literal(text) => text
              Field("github.repository") => context.repository
              Field("github.sha") => context.sha
              Field("github.event_name") => context.event_name
              Field("github.head_ref") => context.head_ref
              Field("github.base_ref") => context.base_ref
              Field(_) => raise InvalidWorkflow("unsupported env context field")
            },
          )
        }
        let resolved = output.to_string()
        guard !resolved.contains("\u{0000}") &&
          @utf8.encode(resolved).length() <= max_source_bytes else {
          raise InvalidWorkflow(
            "resolved env value exceeds 64 KiB or contains NUL",
          )
        }
        if name.strip_prefix("input:") is Some(key) {
          inputs[key.to_owned()] = resolved
        } else {
          env[name] = resolved
        }
      }
      { ..step, env, inputs, }
    })
    { ..job, steps, }
  })
  let result = { ..workflow, jobs, }
  guard @utf8.encode(ToJson::to_json(result).stringify()).length() <= 1048576 else {
    raise InvalidWorkflow("resolved workflow exceeds 1 MiB")
  }
  result
}
