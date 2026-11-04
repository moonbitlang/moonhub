///|
// Captured once, never rebuilt from current branch/MR state.
#derive(Debug, ToJson, FromJson)
pub(all) struct RunContext {
  repository : String
  sha : String
  event_name : String
  head_ref : String
  base_ref : String
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
