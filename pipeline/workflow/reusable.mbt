///|
fn selected_job_closure(
  fields : Map[String, @yaml.Yaml],
  jobs : Array[String],
) -> Map[String, Bool] raise InvalidWorkflow {
  guard !fields.is_empty() && fields.length() <= 16 && jobs.length() <= 16 else {
    raise InvalidWorkflow("workflow requires between 1 and 16 jobs")
  }
  let selected : Map[String, Bool] = Map([])
  for id in jobs {
    guard valid_identifier(id) && fields.contains(id) && !selected.contains(id) else {
      raise InvalidWorkflow("selected jobs must be unique workflow job IDs")
    }
    selected[id] = true
  }
  for _ in 0..<16 {
    let before = selected.length()
    for id in selected.keys().collect() {
      let fields = yaml_as_obj(fields[id], "jobs." + id)
      for
        need in yaml_as_string_list(
          fields.get("needs"),
          "jobs." + id + ".needs",
        ) {
        guard fields.get("uses") is None || need != id else {
          raise InvalidWorkflow("job dependency cycle")
        }
        selected[need] = true
      }
    }
    if selected.length() == before {
      break
    }
    guard selected.keys().all(key => fields.contains(key)) else {
      raise InvalidWorkflow("selected job references an unknown dependency")
    }
  }
  selected
}

///|
fn reusable_path(value : String) -> String raise InvalidWorkflow {
  guard value.strip_prefix("./.github/workflows/") is Some(name) &&
    !name.is_empty() &&
    name.length() <= 200 &&
    !name.contains("..") &&
    (name.has_suffix(".yml") || name.has_suffix(".yaml")) &&
    name
    .iter()
    .all(ch => {
      ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ['-', '_', '.'].contains(ch)
    }) else {
    raise InvalidWorkflow(
      "reusable workflows must use ./.github/workflows/FILE.yml at the caller commit",
    )
  }
  ".github/workflows/" + name.to_owned()
}

///|
pub fn reusable_paths(
  source : String,
  jobs~ : Array[String] = [],
) -> Array[String] raise InvalidWorkflow {
  let fields = yaml_as_obj(read_yaml(source), "workflow")
  let jobs_fields = yaml_as_obj(
    fields.get("jobs").unwrap_or(@yaml.Null),
    "jobs",
  )
  let selected = selected_job_closure(jobs_fields, jobs)
  let result : Array[String] = []
  for id, value in jobs_fields {
    if !selected.is_empty() && !selected.contains(id) {
      continue
    }
    let fields = yaml_as_obj(value, "jobs." + id)
    if fields.get("uses") is Some(value) {
      let path = reusable_path(required_string(Some(value), "job.uses"))
      if !result.contains(path) {
        result.push(path)
      }
    }
  }
  result
}

///|
fn parse_call_inputs(
  value : @yaml.Yaml?,
) -> Array[DispatchInput] raise InvalidWorkflow {
  let inputs = parse_dispatch_inputs(value) catch {
    InvalidWorkflow(message) =>
      raise InvalidWorkflow(
        message.replace_all(old="workflow_dispatch", new="workflow_call"),
      )
  }
  guard inputs.all(input => ["string", "number", "boolean"].contains(input.kind)) else {
    raise InvalidWorkflow(
      "workflow_call supports string, number and boolean inputs",
    )
  }
  if value is Some(value) {
    let declarations = yaml_as_obj(value, "workflow_call.inputs")
    for input in inputs {
      let fields = yaml_as_obj(
        declarations[input.name],
        "workflow_call.inputs." + input.name,
      )
      guard fields.get("type") is Some(String(_)) else {
        raise InvalidWorkflow("workflow_call inputs require an explicit type")
      }
      if fields.get("default") is Some(value) {
        check_call_input_type(input, yaml_snapshot(value))
      }
    }
  }
  inputs
}

///|
fn check_call_input_type(
  input : DispatchInput,
  value : Json,
) -> Unit raise InvalidWorkflow {
  guard (match (input.kind, value) {
    ("string", String(_)) | ("boolean", True | False) => true
    ("number", Number(n, ..)) => !n.is_inf() && !n.is_nan()
    _ => false
  }) else {
    raise InvalidWorkflow(
      "workflow_call input " + input.name + " requires " + input.kind,
    )
  }
}

///|
fn parse_call_outputs(
  value : @yaml.Yaml?,
) -> Map[String, String] raise InvalidWorkflow {
  guard value is Some(value) else { return Map([]) }
  let fields = yaml_as_obj(value, "workflow_call.outputs")
  guard fields.length() <= 100 else {
    raise InvalidWorkflow("too many workflow_call outputs")
  }
  let result : Map[String, String] = Map([])
  for name, value in fields {
    guard valid_identifier(name) &&
      !["__proto__", "constructor", "prototype"].contains(name.to_lower()) &&
      !result.keys().any(key => key.to_lower() == name.to_lower()) else {
      raise InvalidWorkflow("invalid workflow_call output name")
    }
    let fields = yaml_as_obj(value, "workflow_call.outputs." + name)
    check_fields(
      fields,
      ["description", "value"],
      "workflow_call.outputs." + name,
    )
    let text = template_string(
      fields.get("value"),
      "workflow_call output value",
    ).unwrap_or("")
    ignore(
      schedule_template(
        text,
        { "jobs": {}, "inputs": {}, "github": {} },
        validate_output=true,
      ),
    )
    result[name] = text
  }
  result
}

///|
fn parse_reusable_job(
  id : String,
  value : @yaml.Yaml,
  permissions : (Bool, Bool, Int32),
  sources : Map[String, String],
  stack : Array[String],
  budget : Array[Int32],
) -> Job raise InvalidWorkflow {
  let fields = yaml_as_obj(value, "jobs." + id)
  check_fields(
    fields,
    ["name", "uses", "needs", "if", "with", "permissions", "concurrency"],
    "jobs." + id,
  )
  let path = reusable_path(required_string(fields.get("uses"), "job.uses"))
  guard stack.length() < 10 && !stack.contains(path) else {
    raise InvalidWorkflow("reusable workflow cycle or nesting exceeds 10")
  }
  guard sources.get(path) is Some(source) else {
    raise InvalidWorkflow("missing pinned reusable workflow: " + path)
  }
  let next = stack.copy()
  next.push(path)
  let trigger = triggers(source)
  guard trigger.reusable else {
    raise InvalidWorkflow("callee requires on.workflow_call")
  }
  let definition = parse_definition(source, [], sources, next, budget)
  let supplied : Map[String, Json] = Map([])
  if fields.get("with") is Some(value) {
    for name, value in yaml_as_obj(value, "job.with") {
      guard trigger.call_inputs.any(input => input.name == name) else {
        raise InvalidWorkflow("undeclared workflow_call input: " + name)
      }
      let value = yaml_snapshot(value)
      if value is String(text) && text.contains("${{") {
        if whole_scheduling_expression(text) {
          let expression = schedule_parse(text)
          expression.check_context(
            { "github": {}, "inputs": {}, "needs": {}, "vars": {} },
            output=true,
          )
          expression.check_needs(
            yaml_as_string_list(fields.get("needs"), "job.needs"),
          )
        } else {
          ignore(
            schedule_template(
              text,
              { "github": {}, "inputs": {}, "needs": {}, "vars": {} },
              validate_output=true,
            ),
          )
        }
      } else {
        check_call_input_type(
          trigger.call_inputs
          .iter()
          .find_first(input => input.name == name)
          .unwrap(),
          value,
        )
      }
      supplied[name] = value
    }
  }
  for input in trigger.call_inputs {
    guard !input.required ||
      input.default is Some(_) ||
      supplied.contains(input.name) else {
      raise InvalidWorkflow(
        "required workflow_call input is missing: " + input.name,
      )
    }
  }
  let placeholder = fields.copy()
  ignore(placeholder.remove("uses"))
  ignore(placeholder.remove("with"))
  placeholder["runs-on"] = @yaml.String("self-hosted")
  placeholder["steps"] = @yaml.Array([
    @yaml.Map({ "run": @yaml.String("true") }),
  ])
  let job = parse_job(
    id,
    @yaml.Map(placeholder),
    Map([]),
    { shell: None, working_directory: None, },
    permissions,
  )
  guard job.concurrency is None || definition.concurrency is None else {
    raise InvalidWorkflow("caller and callee cannot both declare concurrency")
  }
  let call : ReusableCall = {
    path,
    source,
    definition,
    inputs: trigger.call_inputs,
    supplied,
    outputs: trigger.call_outputs,
  }
  {
    ..job,
    steps: [],
    reusable_call: Some(call),
    concurrency: match job.concurrency {
      Some(value) => Some(value)
      None => definition.concurrency
    },
  }
}

///|
pub fn reusable_inputs(
  job : Job,
  context : Map[String, Json],
) -> Map[String, Json] raise InvalidWorkflow {
  guard job.reusable_call is Some(call) else {
    raise InvalidWorkflow("missing reusable call")
  }
  let supplied : Map[String, Json] = Map([])
  for name, value in call.supplied {
    supplied[name] = match value {
      String(text) if whole_scheduling_expression(text) =>
        scheduling_expression(text, context, extended=true)
      String(text) if text.contains("${{") =>
        Json::string(scheduling_template(text, context, extended=true))
      _ => value
    }
  }
  for name, value in supplied {
    check_call_input_type(
      call.inputs.iter().find_first(input => input.name == name).unwrap(),
      value,
    )
  }
  resolve_dispatch_inputs(call.inputs, supplied)
}

///|
pub fn instantiate_reusable(
  job : Job,
  inputs : Map[String, Json],
) -> Array[Job] raise InvalidWorkflow {
  guard job.reusable_call is Some(call) else {
    raise InvalidWorkflow("missing reusable call")
  }
  let prefix = job.id + "/"
  call.definition.jobs.map(child => {
    ..child,
    id: prefix + child.id,
    needs: child.needs.map(need => prefix + need),
    matrix_group: if child.matrix_group.is_empty() {
      ""
    } else {
      prefix + child.matrix_group
    },
    context_prefix: prefix,
    call_inputs: Some(inputs),
    contents_read: child.contents_read && job.contents_read,
    id_token_write: child.id_token_write && job.id_token_write,
    api_permissions: child.api_permissions & job.api_permissions,
  })
}

///|
pub fn call_output_dependencies(job : Job) -> Job raise InvalidWorkflow {
  guard job.reusable_call is Some(call) else {
    raise InvalidWorkflow("missing reusable call")
  }
  let prefix = job.id + "/"
  {
    ..job,
    needs: call.definition.jobs.map(child => prefix + child.id),
    context_prefix: prefix,
  }
}

///|
pub fn reusable_outputs(
  job : Job,
  jobs : Map[String, Json],
  inputs : Map[String, Json],
  github : Map[String, Json],
) -> Map[String, String] raise InvalidWorkflow {
  guard job.reusable_call is Some(call) else {
    raise InvalidWorkflow("missing reusable call")
  }
  let result : Map[String, String] = Map([])
  let context : Map[String, Json] = {
    "jobs": ToJson::to_json(jobs),
    "inputs": ToJson::to_json(inputs),
    "github": ToJson::to_json(github),
  }
  for name, value in call.outputs {
    let text = scheduling_template(value, context, extended=true)
    guard @utf8.encode(text).length() <= 16384 && !text.contains("\u{0000}") else {
      raise InvalidWorkflow("reusable output exceeds 16 KiB")
    }
    result[name] = text
  }
  guard @utf8.encode(ToJson::to_json(result).stringify()).length() <= 32768 else {
    raise InvalidWorkflow("reusable outputs exceed 32 KiB")
  }
  result
}
