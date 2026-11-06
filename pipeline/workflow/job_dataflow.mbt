///|
fn ScheduleExpr::has_status(self : ScheduleExpr) -> Bool {
  match self {
    Call(name, args) =>
      ["success", "failure", "cancelled", "always"].contains(name) ||
      args.any(arg => arg.has_status())
    Unary(expr) => expr.has_status()
    Binary(_, a, b) => a.has_status() || b.has_status()
    _ => false
  }
}

///|
fn ScheduleExpr::check_needs(
  self : ScheduleExpr,
  needs : Array[String],
) -> Unit raise InvalidWorkflow {
  match self {
    Field(parts) if parts[0] == "needs" && parts.length() > 1 => {
      guard needs.any(need => need.to_lower() == parts[1].to_lower()) else {
        raise InvalidWorkflow(
          "needs context may reference only direct dependencies",
        )
      }
    }
    Unary(expr) => expr.check_needs(needs)
    Binary(_, a, b) => {
      a.check_needs(needs)
      b.check_needs(needs)
    }
    Call(_, args) =>
      for arg in args {
        arg.check_needs(needs)
      }
    _ => ()
  }
}

///|
fn parse_job_condition(
  value : @yaml.Yaml?,
  needs : Array[String],
) -> String raise InvalidWorkflow {
  let text = match value {
    None => "success()"
    Some(String(text)) => text
    Some(Boolean(value)) => value.to_string()
    _ => raise InvalidWorkflow("job.if requires a boolean or expression")
  }
  let expr = schedule_parse(text)
  expr.check_context({ "github": {}, "needs": {}, "__status": {} })
  expr.check_needs(needs)
  text
}

///|
fn parse_job_outputs(
  value : @yaml.Yaml?,
) -> Map[String, String] raise InvalidWorkflow {
  let result : Map[String, String] = Map([])
  guard value is Some(value) else { return result }
  let fields = yaml_as_obj(value, "job.outputs")
  guard fields.length() <= 100 else {
    raise InvalidWorkflow("job.outputs exceeds 100 outputs")
  }
  for name, value in fields {
    guard valid_identifier(name) &&
      !["__proto__", "constructor", "prototype"].contains(name.to_lower()) &&
      !result.keys().any(key => key.to_lower() == name.to_lower()) else {
      raise InvalidWorkflow("invalid or duplicate job output name")
    }
    let text = match value {
      String(text) => text
      Integer(n) => n.to_string()
      Boolean(b) => b.to_string()
      Real(_, repr~) => repr
      _ => raise InvalidWorkflow("job output requires a scalar template")
    }
    validate_template(text, "job.outputs")
    ignore(
      scheduling_template(text, {
        "github": {},
        "needs": {},
        "steps": {},
        "matrix": {},
        "strategy": {},
        "runner": {},
      }),
    )
    result[name] = text
  }
  result
}

///|
pub fn job_condition(
  source : String,
  github : Map[String, Json],
  needs : Map[String, Json],
  success~ : Bool,
  failure~ : Bool,
  cancelled~ : Bool,
) -> Bool raise InvalidWorkflow {
  let expr = schedule_parse(source)
  let context : Map[String, Json] = {
    "github": ToJson::to_json(github),
    "needs": ToJson::to_json(needs),
    "__status": {
      "success": success,
      "failure": failure,
      "cancelled": cancelled,
    },
  }
  expr.check_context(context)
  (expr.has_status() || success) && schedule_truth(expr.evaluate(context))
}
