///|
pub fn valid_secret_name(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= 100 &&
  value.get_char(0) is Some(first) &&
  (first.is_ascii_alphabetic() || first == '_') &&
  value
  .iter()
  .all(ch => ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_') &&
  !["GITHUB_", "MOONHUB_", "RUNNER_"].any(prefix => {
    value.to_upper().has_prefix(prefix)
  })
}

///|
// Secret expressions are whole env values, never mixed with public context.
fn secret_reference(value : String) -> String? raise InvalidWorkflow {
  guard value.has_prefix("${{") && value.has_suffix("}}") else { return None }
  let expression = value[3:value.length() - 2].trim().to_owned()
  guard expression.strip_prefix("secrets.") is Some(name) else { return None }
  let name = name.to_owned()
  guard valid_secret_name(name) else {
    raise InvalidWorkflow("invalid secret reference; use secrets.NAME")
  }
  Some(name.to_upper())
}
