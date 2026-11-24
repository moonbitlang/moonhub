///|
// New literal numeric indexes need the v14 runtime. Ignore brackets in script
// text and quoted expression strings, including JSON passed to fromJSON.
fn needs_index_runtime(source : String) -> Bool {
  let mut rest = source
  while rest.split_once("${{") is Some((_, expression)) {
    let chars = expression.to_owned().to_array()
    let mut quoted = false
    let mut end = chars.length()
    let mut i = 0
    while i < chars.length() {
      if chars[i] == '\'' {
        if quoted && i + 1 < chars.length() && chars[i + 1] == '\'' {
          i += 2
          continue
        }
        quoted = !quoted
      }
      if !quoted && chars[i] == '[' {
        let mut next = i + 1
        while next < chars.length() &&
              [' ', '\n', '\r', '\t'].contains(chars[next]) {
          next += 1
        }
        if next < chars.length() && chars[next].is_ascii_digit() {
          return true
        }
      }
      if !quoted &&
        chars[i] == '}' &&
        i + 1 < chars.length() &&
        chars[i + 1] == '}' {
        end = i + 2
        break
      }
      i += 1
    }
    rest = String::from_array(chars[end:].to_owned())
  }
  false
}

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
