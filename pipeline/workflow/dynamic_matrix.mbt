///|
fn yaml_snapshot(value : @yaml.Yaml) -> Json raise InvalidWorkflow {
  match value {
    Map(fields) => Json::object(fields.map((_, value) => yaml_snapshot(value)))
    Array(items) => Json::array(items.map(yaml_snapshot))
    String(value) => Json::string(value)
    Integer(value) => Json::number(value.to_double())
    Real(_, repr~) =>
      @json.parse(repr) catch {
        _ => raise InvalidWorkflow("invalid YAML number")
      }
    Boolean(value) => Json::boolean(value)
    Null => Json::null()
    _ => raise InvalidWorkflow("unsupported YAML snapshot value")
  }
}

///|
fn snapshot_yaml(value : Json) -> @yaml.Yaml {
  match value {
    Object(fields) => @yaml.Map(fields.map((_, value) => snapshot_yaml(value)))
    Array(items) => @yaml.Array(items.map(snapshot_yaml))
    String(value) => @yaml.String(value)
    Number(value, repr~) =>
      if value == value.to_int64().to_double() {
        @yaml.Integer(value.to_int64())
      } else {
        @yaml.Real(value, repr=repr.unwrap_or(value.to_string()))
      }
    True => @yaml.Boolean(true)
    False => @yaml.Boolean(false)
    Null => @yaml.Null
  }
}

///|
pub fn expand_dynamic_matrix(
  job : Job,
  context : Map[String, Json],
  remaining_jobs~ : Int32,
  remaining_steps~ : Int32,
  remaining_bytes~ : Int32,
) -> (Json, Array[Job]) raise InvalidWorkflow {
  guard job.dynamic_matrix is Some(template) else {
    raise InvalidWorkflow("missing matrix template")
  }
  let value = scheduling_expression(template.expression, context, extended=true)
  validate_expression_json(value, 0, [0])
  guard @utf8.encode(value.stringify()).length() <= max_source_bytes else {
    raise InvalidWorkflow("dynamic matrix exceeds 64 KiB")
  }
  let fields = yaml_as_obj(snapshot_yaml(template.source), "dynamic job")
  let strategy = yaml_as_obj(fields.get("strategy").unwrap(), "strategy")
  strategy["matrix"] = snapshot_yaml(value)
  let jobs = expand_job(
    job.id,
    @yaml.Map(fields),
    template.env,
    { shell: template.shell, working_directory: template.directory, },
    (template.contents_read, template.id_token_write, template.api_permissions),
    remaining_jobs~,
    remaining_steps~,
    remaining_bytes~,
    base_context=context,
  )
  let jobs = jobs.map(child => {
    ..child,
    needs: job.needs,
    condition: "always()",
    // These fields were resolved against the pinned event when the template
    // was saved. Display names and matrix/runtime templates stay per instance.
    steps: child.steps.mapi((index, step) => {
      ..step,
      env: job.steps[index].env,
      inputs: job.steps[index].inputs,
    }),
  })
  guard jobs.fold(init=0, (bytes, job) => {
      bytes + @utf8.encode(ToJson::to_json(job).stringify()).length()
    }) <=
    remaining_bytes else {
    raise InvalidWorkflow("normalized workflow exceeds 1 MiB")
  }
  (value, jobs)
}
