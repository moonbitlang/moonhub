///|
#derive(Debug, ToJson, FromJson)
pub struct DispatchInput {
  name : String
  description : String
  kind : String
  required : Bool
  default : Json?
  options : Array[String]
}

///|
fn dispatch_input_value(
  kind : String,
  value : Json,
  options : Array[String],
  ctx : String,
) -> Json raise InvalidWorkflow {
  let result = match (kind, value) {
    ("string", String(_)) => value
    ("choice", String(text)) if options.contains(text) => value
    ("boolean", True | False) => value
    ("boolean", String("true")) => Json::boolean(true)
    ("boolean", String("false")) => Json::boolean(false)
    ("number", Number(number, ..)) if number.is_finite() => value
    ("number", String(text)) => {
      let value = @json.parse(text.trim()) catch {
        _ => raise InvalidWorkflow(ctx + " requires a finite number")
      }
      guard value is Number(number, ..) && number.is_finite() else {
        raise InvalidWorkflow(ctx + " requires a finite number")
      }
      value
    }
    _ => raise InvalidWorkflow(ctx + " requires a valid " + kind + " input")
  }
  guard !(result is String(text) && text.contains("\u{0000}")) &&
    @utf8.encode(result.stringify()).length() <= 65535 else {
    raise InvalidWorkflow(ctx + " exceeds input limits")
  }
  result
}

///|
fn parse_dispatch_inputs(
  value : @yaml.Yaml?,
) -> Array[DispatchInput] raise InvalidWorkflow {
  guard value is Some(value) else { return [] }
  let fields = yaml_as_obj(value, "on.workflow_dispatch.inputs")
  guard fields.length() <= 25 else {
    raise InvalidWorkflow("workflow_dispatch accepts at most 25 inputs")
  }
  let result : Array[DispatchInput] = []
  for name, value in fields {
    guard valid_identifier(name) &&
      !["__proto__", "prototype", "constructor"].contains(name.to_lower()) &&
      !result.any(input => input.name.to_lower() == name.to_lower()) else {
      raise InvalidWorkflow("invalid or duplicate dispatch input name")
    }
    let ctx = "on.workflow_dispatch.inputs." + name
    let fields = yaml_as_obj(value, ctx)
    check_fields(
      fields,
      ["description", "required", "default", "type", "options"],
      ctx,
    )
    let description = match fields.get("description") {
      None => ""
      Some(String(text)) if @utf8.encode(text).length() <= 1024 => text
      _ =>
        raise InvalidWorkflow(
          ctx + ".description requires a string up to 1024 bytes",
        )
    }
    let kind = match fields.get("type") {
      None => "string"
      Some(String(kind)) if ["string", "boolean", "number", "choice"].contains(
          kind,
        ) => kind
      Some(String("environment")) =>
        raise InvalidWorkflow("environment dispatch inputs are not supported")
      _ =>
        raise InvalidWorkflow(
          ctx + ".type requires string, boolean, number or choice",
        )
    }
    let required = match fields.get("required") {
      None => false
      Some(Boolean(value)) => value
      _ => raise InvalidWorkflow(ctx + ".required requires a boolean")
    }
    let options : Array[String] = match fields.get("options") {
      Some(Array(values)) if kind == "choice" &&
        !values.is_empty() &&
        values.length() <= 100 => {
        let options : Array[String] = []
        for value in values {
          guard value is String(text) &&
            !text.is_empty() &&
            @utf8.encode(text).length() <= 1024 &&
            !options.contains(text) else {
            raise InvalidWorkflow(
              ctx + ".options requires unique nonempty strings",
            )
          }
          options.push(text)
        }
        options
      }
      None if kind != "choice" => []
      _ =>
        raise InvalidWorkflow(
          ctx + ".options is required only for choice inputs",
        )
    }
    let default = fields
      .get("default")
      .map(value => {
        let value = match value {
          String(text) => Json::string(text)
          Integer(number) =>
            Json::number(number.to_double(), repr=number.to_string())
          Real(number, ..) if number.is_finite() => Json::number(number)
          Boolean(value) => Json::boolean(value)
          _ => raise InvalidWorkflow(ctx + ".default requires a finite scalar")
        }
        let value = dispatch_input_value(kind, value, options, ctx + ".default")
        guard !(required && value == Json::string("")) else {
          raise InvalidWorkflow(ctx + ".default is empty for a required input")
        }
        value
      })
    result.push({ name, description, kind, required, default, options, })
  }
  result
}

///|
// Convert form/CLI strings while preserving JSON types in the immutable context.
pub fn resolve_dispatch_inputs(
  definitions : Array[DispatchInput],
  supplied : Map[String, Json],
) -> Map[String, Json] raise InvalidWorkflow {
  guard supplied.length() <= 25 &&
    @utf8.encode(ToJson::to_json(supplied).stringify()).length() <= 65535 else {
    raise InvalidWorkflow(
      "dispatch input payload exceeds 65535 bytes or 25 inputs",
    )
  }
  for name, _ in supplied {
    guard definitions.any(input => input.name == name) else {
      raise InvalidWorkflow("unknown dispatch input: " + name)
    }
  }
  let result : Map[String, Json] = Map([])
  for definition in definitions {
    let name = definition.name
    let provided = match supplied.get(name) {
      Some(value) => Some(value)
      None => definition.default
    }
    let value = match provided {
      Some(value) => value
      None if definition.required =>
        raise InvalidWorkflow("required dispatch input is missing: " + name)
      None =>
        match definition.kind {
          "boolean" => Json::boolean(false)
          "number" => Json::number(0.0)
          "choice" => Json::string("")
          _ => Json::string("")
        }
    }
    let value = if provided is None && definition.kind == "choice" {
      value
    } else {
      dispatch_input_value(
        definition.kind,
        value,
        definition.options,
        "dispatch input " + name,
      )
    }
    guard !(definition.required && value == Json::string("")) else {
      raise InvalidWorkflow("required dispatch input is empty: " + name)
    }
    result[name] = value
  }
  guard @utf8.encode(ToJson::to_json(result).stringify()).length() <= 65535 else {
    raise InvalidWorkflow("resolved dispatch inputs exceed 65535 bytes")
  }
  result
}
