///|
priv enum ScheduleExpr {
  Value(Json)
  Field(Array[String])
  Unary(ScheduleExpr)
  Binary(String, ScheduleExpr, ScheduleExpr)
  Call(String, Array[ScheduleExpr])
}

///|
priv struct ScheduleParser {
  tokens : Array[String]
  mut index : Int32
}

///|
fn schedule_tokens(source : String) -> Array[String] raise InvalidWorkflow {
  guard @utf8.encode(source).length() <= max_source_bytes &&
    !source.contains("\u{0000}") else {
    raise InvalidWorkflow("scheduling expression exceeds limits")
  }
  let text = source.trim().to_owned()
  let text = if text.has_prefix("${{") && text.has_suffix("}}") {
    text[3:text.length() - 2].to_owned()
  } else {
    text
  }
  let chars = text.to_array()
  let tokens : Array[String] = []
  let mut i = 0
  while i < chars.length() {
    let ch = chars[i]
    if ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' {
      i += 1
      continue
    }
    let start = i
    i += 1
    if ch == '\'' {
      let value = StringBuilder()
      let mut closed = false
      while i < chars.length() {
        if chars[i] == '\'' {
          i += 1
          if i < chars.length() && chars[i] == '\'' {
            value.write_char('\'')
            i += 1
          } else {
            closed = true
            break
          }
        } else {
          value.write_char(chars[i])
          i += 1
        }
      }
      guard closed else {
        raise InvalidWorkflow("unterminated scheduling string")
      }
      tokens.push("'" + value.to_string())
    } else if ch.is_ascii_alphabetic() || ch == '_' {
      while i < chars.length() &&
            (
              chars[i].is_ascii_alphabetic() ||
              chars[i].is_ascii_digit() ||
              chars[i] == '_' ||
              chars[i] == '-'
            ) {
        i += 1
      }
      tokens.push(String::from_array(chars[start:i].to_owned()).to_lower())
    } else if ch.is_ascii_digit() || ch == '-' {
      while i < chars.length() &&
            (
              chars[i].is_ascii_digit() ||
              ['.', 'e', 'E', '+', '-'].contains(chars[i])
            ) {
        i += 1
      }
      tokens.push(String::from_array(chars[start:i].to_owned()))
    } else if ['=', '!', '<', '>', '&', '|'].contains(ch) &&
      i < chars.length() &&
      (
        (chars[i] == '=' && ['=', '!', '<', '>'].contains(ch)) ||
        (chars[i] == ch && ['&', '|'].contains(ch))
      ) {
      tokens.push(ch.to_string() + chars[i].to_string())
      i += 1
    } else if ['!', '<', '>', '(', ')', '.', '[', ']', ','].contains(ch) {
      tokens.push(ch.to_string())
    } else {
      raise InvalidWorkflow("unsupported scheduling expression syntax")
    }
    guard tokens.length() <= 512 else {
      raise InvalidWorkflow("scheduling expression exceeds token limit")
    }
  }
  tokens
}

///|
fn ScheduleParser::take(self : ScheduleParser, token : String) -> Bool {
  if self.index < self.tokens.length() && self.tokens[self.index] == token {
    self.index += 1
    true
  } else {
    false
  }
}

///|
fn ScheduleParser::expect(
  self : ScheduleParser,
  token : String,
) -> Unit raise InvalidWorkflow {
  guard self.take(token) else {
    raise InvalidWorkflow("invalid scheduling expression")
  }
}

///|
fn ScheduleParser::atom(
  self : ScheduleParser,
  depth : Int32,
) -> ScheduleExpr raise InvalidWorkflow {
  guard depth <= 32 && self.index < self.tokens.length() else {
    raise InvalidWorkflow("invalid or nested scheduling expression")
  }
  if self.take("!") {
    return Unary(self.atom(depth + 1))
  }
  if self.take("(") {
    let node = self.binary(0, depth + 1)
    self.expect(")")
    return node
  }
  let token = self.tokens[self.index]
  self.index += 1
  if token.has_prefix("'") {
    return Value(Json::string(token[1:].to_owned()))
  }
  if token == "true" {
    return Value(Json::boolean(true))
  }
  if token == "false" {
    return Value(Json::boolean(false))
  }
  if token == "null" {
    return Value(Json::null())
  }
  if token.get_char(0) is Some(ch) && (ch.is_ascii_digit() || ch == '-') {
    return Value(
      @json.parse(token) catch {
        _ => raise InvalidWorkflow("invalid scheduling number")
      },
    )
  }
  if self.take("(") {
    let args : Array[ScheduleExpr] = []
    if !self.take(")") {
      for ;; {
        args.push(self.binary(0, depth + 1))
        if !self.take(",") {
          break
        }
      }
      self.expect(")")
    }
    guard [
      "contains", "startswith", "endswith", "format", "success", "failure", "cancelled",
      "always", "join", "fromjson", "tojson",
    ].contains(token) else {
      raise InvalidWorkflow("unsupported scheduling function: " + token)
    }
    return Call(token, args)
  }
  guard [
    "github", "matrix", "strategy", "needs", "steps", "runner", "env", "inputs",
    "vars", "jobs",
  ].contains(token) else {
    raise InvalidWorkflow("unsupported scheduling context: " + token)
  }
  let fields = [token]
  while self.take(".") || self.take("[") {
    let bracket = self.tokens[self.index - 1] == "["
    guard self.index < self.tokens.length() else {
      raise InvalidWorkflow("missing scheduling context field")
    }
    let part = self.tokens[self.index]
    self.index += 1
    let quoted = part.has_prefix("'")
    let numeric = !part.is_empty() &&
      (part == "0" || !part.has_prefix("0")) &&
      part.to_array().all(ch => ch.is_ascii_digit())
    let field = if bracket && quoted { part[1:].to_owned() } else { part }
    guard (if bracket { quoted || numeric } else { valid_identifier(part) }) &&
      !["constructor", "__proto__", "prototype"].contains(field.to_lower()) else {
      raise InvalidWorkflow("invalid scheduling field")
    }
    fields.push(field)
    if bracket {
      self.expect("]")
    }
  }
  Field(fields)
}

///|
fn ScheduleParser::binary(
  self : ScheduleParser,
  minimum : Int32,
  depth : Int32,
) -> ScheduleExpr raise InvalidWorkflow {
  let mut left = self.atom(depth)
  while self.index < self.tokens.length() {
    let op = self.tokens[self.index]
    let precedence = match op {
      "||" => 1
      "&&" => 2
      "==" | "!=" => 3
      "<" | "<=" | ">" | ">=" => 4
      _ => 0
    }
    if precedence == 0 || precedence < minimum {
      break
    }
    self.index += 1
    left = Binary(op, left, self.binary(precedence + 1, depth + 1))
  }
  left
}

///|
fn schedule_parse(source : String) -> ScheduleExpr raise InvalidWorkflow {
  let parser = { tokens: schedule_tokens(source), index: 0, }
  let expr = parser.binary(0, 0)
  guard parser.index == parser.tokens.length() else {
    raise InvalidWorkflow("trailing scheduling expression tokens")
  }
  expr
}

///|
fn schedule_truth(value : Json) -> Bool {
  match value {
    Null | False => false
    String(text) => !text.is_empty()
    Number(n, ..) => n != 0.0
    _ => true
  }
}

///|
fn schedule_string(value : Json) -> String {
  match value {
    String(text) => text
    Null => ""
    _ => value.stringify()
  }
}

///|
fn schedule_array_field(items : Array[Json], key : String) -> Json? {
  guard !key.is_empty() && (key == "0" || !key.has_prefix("0")) else {
    return None
  }
  let length = items.length().to_int64()
  let mut index = 0L
  for digit in key {
    guard digit.is_ascii_digit() else { return None }
    index = index * 10L + (digit.to_int() - '0'.to_int()).to_int64()
    guard index < length else { return None }
  }
  Some(items[index.to_int()])
}

///|
fn ScheduleExpr::evaluate(
  self : ScheduleExpr,
  context : Map[String, Json],
) -> Json raise InvalidWorkflow {
  match self {
    Value(value) => value
    Field(parts) => {
      guard context.contains(parts[0]) else {
        raise InvalidWorkflow("unavailable scheduling context: " + parts[0])
      }
      let mut value : Json = ToJson::to_json(context)
      for part in parts {
        value = (match value {
          Object(fields) =>
            fields
            .iter()
            .find_first(entry => entry.0.to_lower() == part.to_lower())
            .map(entry => entry.1)
          Array(items) => schedule_array_field(items, part)
          _ => None
        }).unwrap_or(Json::string(""))
      }
      value
    }
    Unary(expr) => Json::boolean(!schedule_truth(expr.evaluate(context)))
    Binary(op, left, right) => {
      let left = left.evaluate(context)
      match op {
        "&&" =>
          if schedule_truth(left) {
            right.evaluate(context)
          } else {
            left
          }
        "||" =>
          if schedule_truth(left) {
            left
          } else {
            right.evaluate(context)
          }
        _ => {
          let right = right.evaluate(context)
          Json::boolean(
            match op {
              "==" => schedule_equal(left, right)
              "!=" => !schedule_equal(left, right)
              _ => {
                let order = match (left, right) {
                  (String(a), String(b)) =>
                    Some(a.to_lower().compare(b.to_lower()))
                  _ =>
                    match (schedule_number(left), schedule_number(right)) {
                      (Some(a), Some(b)) if !a.is_nan() && !b.is_nan() =>
                        Some(a.compare(b))
                      _ => None
                    }
                }
                match order {
                  Some(n) =>
                    match op {
                      "<" => n < 0
                      "<=" => n <= 0
                      ">" => n > 0
                      _ => n >= 0
                    }
                  None => false
                }
              }
            },
          )
        }
      }
    }
    Call(name, args) => {
      if ["success", "failure", "cancelled", "always"].contains(name) {
        guard args.is_empty() && context.get("__status") is Some(Object(status)) else {
          raise InvalidWorkflow("status function unavailable in this context")
        }
        return if name == "always" {
          Json::boolean(true)
        } else {
          status.get(name).unwrap_or(Json::boolean(false))
        }
      }
      let args = args.map(arg => arg.evaluate(context))
      if name == "fromjson" && args.length() == 1 {
        guard args[0] is String(text) &&
          @utf8.encode(text).length() <= max_source_bytes else {
          raise InvalidWorkflow("fromJSON requires a bounded string")
        }
        let value = @json.parse(text) catch {
          _ => raise InvalidWorkflow("invalid fromJSON input")
        }
        validate_expression_json(value, 0, [0])
        value
      } else if name == "tojson" && args.length() == 1 {
        let text = args[0].stringify()
        guard @utf8.encode(text).length() <= max_source_bytes else {
          raise InvalidWorkflow("toJSON exceeds limits")
        }
        Json::string(text)
      } else if name == "join" && (args.length() == 1 || args.length() == 2) {
        let separator = if args.length() == 2 {
          schedule_string(args[1])
        } else {
          ","
        }
        let values = match args[0] {
          Array(items) => items.map(schedule_string)
          value => [schedule_string(value)]
        }
        guard values.fold(init=0, (size, value) => {
            size + @utf8.encode(value).length()
          }) +
          values.length() * @utf8.encode(separator).length() <=
          max_source_bytes else {
          raise InvalidWorkflow("join exceeds limits")
        }
        Json::string(values.join(separator))
      } else if name == "format" && args.length() > 0 {
        Json::string(schedule_format(args))
      } else {
        guard args.length() == 2 else {
          raise InvalidWorkflow("scheduling function requires two arguments")
        }
        let a = schedule_string(args[0]).to_lower()
        let b = schedule_string(args[1]).to_lower()
        Json::boolean(
          match name {
            "contains" =>
              match args[0] {
                Array(items) => items.any(item => schedule_equal(item, args[1]))
                _ => a.contains(b)
              }
            "startswith" => a.has_prefix(b)
            "endswith" => a.has_suffix(b)
            _ => false
          },
        )
      }
    }
  }
}

///|
fn ScheduleExpr::check_context(
  self : ScheduleExpr,
  context : Map[String, Json],
  output~ : Bool = false,
) -> Unit raise InvalidWorkflow {
  match self {
    Field(parts) => {
      guard context.contains(parts[0]) else {
        raise InvalidWorkflow("unavailable scheduling context: " + parts[0])
      }
    }
    Unary(expr) => expr.check_context(context, output~)
    Binary(op, left, right) => {
      guard output || !["<", "<=", ">", ">="].contains(op) else {
        raise InvalidWorkflow("unsupported scheduling operator: " + op)
      }
      left.check_context(context, output~)
      right.check_context(context, output~)
    }
    Call(name, args) => {
      guard output || !["join", "fromjson", "tojson"].contains(name) else {
        raise InvalidWorkflow("unsupported scheduling function: " + name)
      }
      if ["success", "failure", "cancelled", "always"].contains(name) {
        guard args.is_empty() && context.contains("__status") else {
          raise InvalidWorkflow("status function unavailable in this context")
        }
      }
      guard (if name == "join" {
        args.length() == 1 || args.length() == 2
      } else if name == "fromjson" || name == "tojson" {
        args.length() == 1
      } else if name == "format" {
        !args.is_empty()
      } else if ["success", "failure", "cancelled", "always"].contains(name) {
        true
      } else {
        args.length() == 2
      }) else {
        raise InvalidWorkflow("invalid scheduling function arity")
      }
      for arg in args {
        arg.check_context(context, output~)
      }
    }
    Value(_) => ()
  }
}

///|
pub fn scheduling_expression(
  source : String,
  context : Map[String, Json],
  extended~ : Bool = false,
) -> Json raise InvalidWorkflow {
  let expr = schedule_parse(source)
  expr.check_context(context, output=extended)
  expr.evaluate(context)
}

///|
fn whole_scheduling_expression(source : String) -> Bool {
  let text = source.trim().to_owned()
  if !text.has_prefix("${{") || !text.has_suffix("}}") {
    return false
  }
  let chars = text.to_array()
  let mut quoted = false
  let mut i = 3
  while i + 1 < chars.length() {
    if chars[i] == '\'' {
      if quoted && chars[i + 1] == '\'' {
        i += 2
        continue
      }
      quoted = !quoted
    }
    if !quoted && chars[i] == '}' && chars[i + 1] == '}' {
      return i + 2 == chars.length()
    }
    i += 1
  }
  false
}

///|
pub fn scheduling_template(
  source : String,
  context : Map[String, Json],
  extended~ : Bool = false,
) -> String raise InvalidWorkflow {
  schedule_template(source, context, validate_output=false, extended~)
}

///|
fn schedule_template(
  source : String,
  context : Map[String, Json],
  validate_output~ : Bool,
  extended~ : Bool = false,
) -> String raise InvalidWorkflow {
  guard @utf8.encode(source).length() <= max_source_bytes &&
    !source.contains("\u{0000}") else {
    raise InvalidWorkflow("scheduling template exceeds limits")
  }
  let output = StringBuilder()
  let mut size = 0
  let append = (text : String) => {
    size += @utf8.encode(text).length()
    guard size <= max_source_bytes && !text.contains("\u{0000}") else {
      raise InvalidWorkflow("scheduling template exceeds limits")
    }
    output.write_string(text)
  }
  let mut rest = source
  while rest.split_once("${{") is Some((before, code)) {
    append(before.to_owned())
    // Find the closing delimiter outside quoted strings.
    let chars = code.to_owned().to_array()
    let mut quoted = false
    let mut end = -1
    let mut i = 0
    while i + 1 < chars.length() {
      if chars[i] == '\'' {
        if quoted && chars[i + 1] == '\'' {
          i += 2
          continue
        }
        quoted = !quoted
      }
      if !quoted && chars[i] == '}' && chars[i + 1] == '}' {
        end = i
        break
      }
      i += 1
    }
    guard end >= 0 else {
      raise InvalidWorkflow("unterminated scheduling template")
    }
    let expr = schedule_parse(String::from_array(chars[:end].to_owned()))
    expr.check_context(context, output=validate_output || extended)
    if !validate_output {
      append(schedule_string(expr.evaluate(context)))
    }
    rest = String::from_array(chars[end + 2:].to_owned())
  }
  append(rest)
  let result = output.to_string()
  guard result.length() <= max_source_bytes && !result.contains("\u{0000}") else {
    raise InvalidWorkflow("scheduling template exceeds limits")
  }
  result
}

///|
fn schedule_number(value : Json) -> Double? {
  match value {
    Null | False => Some(0.0)
    True => Some(1.0)
    Number(n, ..) => Some(n)
    String(text) => {
      let text = text.trim().to_owned()
      if text.is_empty() {
        return Some(0.0)
      }
      match (@json.parse(text) catch { _ => return None }) {
        Number(n, ..) => Some(n)
        _ => None
      }
    }
    _ => None
  }
}

///|
fn schedule_equal(left : Json, right : Json) -> Bool {
  match (left, right) {
    (String(a), String(b)) => a.to_lower() == b.to_lower()
    (Object(_), _) | (Array(_), _) | (_, Object(_)) | (_, Array(_)) => false
    _ =>
      match (schedule_number(left), schedule_number(right)) {
        (Some(a), Some(b)) => a == b
        _ => left == right
      }
  }
}

///|
fn schedule_format(args : Array[Json]) -> String raise InvalidWorkflow {
  let chars = schedule_string(args[0]).to_array()
  let out = StringBuilder()
  let mut size = 0
  let mut i = 0
  while i < chars.length() {
    if i + 1 < chars.length() &&
      (
        (chars[i] == '{' && chars[i + 1] == '{') ||
        (chars[i] == '}' && chars[i + 1] == '}')
      ) {
      size += @utf8.encode(chars[i].to_string()).length()
      guard size <= max_source_bytes else {
        raise InvalidWorkflow("formatted expression exceeds limits")
      }
      out.write_char(chars[i])
      i += 2
    } else if chars[i] == '{' {
      i += 1
      let mut index = 0
      let start = i
      while i < chars.length() && chars[i].is_ascii_digit() {
        index = index * 10 + chars[i].to_int() - 48
        guard index < 512 else {
          raise InvalidWorkflow("format index exceeds limits")
        }
        i += 1
      }
      guard i > start &&
        i < chars.length() &&
        chars[i] == '}' &&
        index + 1 < args.length() else {
        raise InvalidWorkflow("invalid format placeholder")
      }
      let text = schedule_string(args[index + 1])
      size += @utf8.encode(text).length()
      guard size <= max_source_bytes else {
        raise InvalidWorkflow("formatted expression exceeds limits")
      }
      out.write_string(text)
      i += 1
    } else {
      guard chars[i] != '}' else {
        raise InvalidWorkflow("unescaped format brace")
      }
      size += @utf8.encode(chars[i].to_string()).length()
      guard size <= max_source_bytes else {
        raise InvalidWorkflow("formatted expression exceeds limits")
      }
      out.write_char(chars[i])
      i += 1
    }
    guard size <= max_source_bytes else {
      raise InvalidWorkflow("formatted expression exceeds limits")
    }
  }
  out.to_string()
}

///|
fn validate_expression_json(
  value : Json,
  depth : Int32,
  count : Array[Int32],
) -> Unit raise InvalidWorkflow {
  count[0] += 1
  guard depth <= 32 && count[0] <= 8192 else {
    raise InvalidWorkflow("JSON expression exceeds limits")
  }
  match value {
    Object(fields) =>
      for key, value in fields {
        guard !["__proto__", "constructor", "prototype"].contains(
          key.to_lower(),
        ) else {
          raise InvalidWorkflow("unsafe JSON field")
        }
        validate_expression_json(value, depth + 1, count)
      }
    Array(items) =>
      for item in items {
        validate_expression_json(item, depth + 1, count)
      }
    Number(number, ..) => {
      guard !number.is_nan() && !number.is_inf() else {
        raise InvalidWorkflow("JSON expression requires finite numbers")
      }
    }
    _ => ()
  }
}
