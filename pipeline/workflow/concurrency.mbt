///|
fn parse_concurrency(
  value : @yaml.Yaml?,
  job~ : Bool = false,
) -> Concurrency? raise InvalidWorkflow {
  guard value is Some(value) else { return None }
  let fields = match value {
    String(group) => Map([("group", @yaml.String(group))])
    _ => yaml_as_obj(value, "concurrency")
  }
  check_fields(fields, ["group", "cancel-in-progress", "queue"], "concurrency")
  let group = template_string(fields.get("group"), "concurrency.group").unwrap_or(
    "",
  )
  guard !group.trim().is_empty() && group.length() <= 1024 else {
    raise InvalidWorkflow("concurrency.group requires 1 to 1024 characters")
  }
  let cancel_in_progress = match fields.get("cancel-in-progress") {
    None => "false"
    Some(Boolean(value)) => value.to_string()
    Some(String(value)) => value
    _ =>
      raise InvalidWorkflow(
        "concurrency.cancel-in-progress requires boolean or expression",
      )
  }
  let empty : Map[String, Json] = {
    "github": ({} : Json),
    "inputs": ({} : Json),
    "vars": ({} : Json),
  }
  if job {
    empty["needs"] = {}
    empty["matrix"] = {}
    empty["strategy"] = {}
  }
  ignore(schedule_template(group, empty, validate_output=true))
  schedule_parse(cancel_in_progress).check_context(empty)
  let queue_max = match fields.get("queue") {
    None => false
    Some(String("max")) => true
    _ => raise InvalidWorkflow("concurrency.queue supports only max")
  }
  guard !queue_max || cancel_in_progress.trim() == "false" else {
    raise InvalidWorkflow("queue: max cannot cancel in-progress work")
  }
  Some({ group, cancel_in_progress, queue_max, })
}

///|
pub fn Concurrency::resolve(
  self : Concurrency,
  github : Map[String, Json],
  inputs~ : Map[String, Json] = Map([]),
  variables~ : Map[String, String]? = None,
  job_context~ : Map[String, Json]? = None,
) -> (String, Bool) raise InvalidWorkflow {
  let context = {
    "github": ToJson::to_json(github),
    "inputs": ToJson::to_json(inputs),
  }
  if variables is Some(variables) {
    context["vars"] = ToJson::to_json(variables)
  }
  if job_context is Some(extra) {
    for key in ["needs", "matrix", "strategy"] {
      context[key] = extra.get(key).unwrap_or(({} : Json))
    }
  }
  let group = scheduling_template(self.group, context)
  guard !group.trim().is_empty() && @utf8.encode(group).length() <= 256 else {
    raise InvalidWorkflow("resolved concurrency group requires 1 to 256 bytes")
  }
  let cancel = scheduling_expression(self.cancel_in_progress, context)
  guard cancel is True || cancel is False else {
    raise InvalidWorkflow(
      "concurrency.cancel-in-progress must evaluate to boolean",
    )
  }
  (group.to_lower(), cancel is True)
}
