///|
fn runtime_template(value : String) -> Bool {
  value.contains("${{") &&
  (try {
    ignore(env_segments(value, "template"))
    false
  } catch {
    _ => true
  })
}

///|
fn validate_template(
  value : String,
  ctx : String,
) -> Unit raise InvalidWorkflow {
  guard !value.contains("\u{0000}") &&
    @utf8.encode(value).length() <= max_source_bytes else {
    raise InvalidWorkflow("\{ctx}: invalid or oversized template")
  }
  // Secrets have a separate execution-time channel. Never silently interpret
  // unknown/mixed secret references as empty expression context fields.
  let mut rest = value
  while rest.split_once("${{") is Some((_, expression)) {
    guard expression.split_once("}}") is Some((code, after)) else {
      raise InvalidWorkflow("\{ctx}: unterminated expression")
    }
    guard !code.trim().is_empty() else {
      raise InvalidWorkflow("\{ctx}: empty expression")
    }
    let mut quoted = false
    let mut token = StringBuilder()
    for ch in code.to_owned() + " " {
      if ch == '\'' {
        quoted = !quoted
      }
      if !quoted &&
        (ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_') {
        token.write_char(ch)
      } else {
        guard token.to_string().to_lower() != "secrets" else {
          raise InvalidWorkflow(
            "\{ctx}: secret expressions require an entire env or with value",
          )
        }
        token = StringBuilder()
      }
    }
    rest = after.to_owned()
  }
}

///|
fn template_string(
  value : @yaml.Yaml?,
  ctx : String,
) -> String? raise InvalidWorkflow {
  match value {
    None => None
    Some(String(text)) => {
      validate_template(text, ctx)
      Some(text)
    }
    _ => raise InvalidWorkflow("\{ctx} must be a string")
  }
}
