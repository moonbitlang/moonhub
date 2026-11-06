///|
fn parse_concurrency(value : @yaml.Yaml?) -> Concurrency? raise InvalidWorkflow {
  guard value is Some(value) else { return None }
  let fields = match value {
    String(group) => Map([("group", @yaml.String(group))])
    _ => yaml_as_obj(value, "concurrency")
  }
  check_fields(fields, ["group", "cancel-in-progress"], "concurrency")
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
  }
  ignore(scheduling_template(group, empty))
  ignore(scheduling_expression(cancel_in_progress, empty))
  Some({ group, cancel_in_progress, })
}

///|
pub fn Concurrency::resolve(
  self : Concurrency,
  github : Map[String, Json],
  inputs~ : Map[String, Json] = Map([]),
) -> (String, Bool) raise InvalidWorkflow {
  let context = {
    "github": ToJson::to_json(github),
    "inputs": ToJson::to_json(inputs),
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
