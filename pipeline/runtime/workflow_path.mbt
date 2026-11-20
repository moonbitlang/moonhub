///|
pub fn validate_workflow_path(path : String) -> Unit raise {
  let parts = path.split("/").collect()
  guard parts.length() == 3 &&
    parts[0] == ".github" &&
    parts[1] == "workflows" &&
    path.length() <= 240 &&
    (path.has_suffix(".yml") || path.has_suffix(".yaml")) &&
    parts[2].length() > 4 &&
    parts[2].get_char(0) is Some(first) &&
    (first.is_ascii_alphabetic() || first.is_ascii_digit() || first == '_') &&
    parts[2]
    .iter()
    .all(ch => {
      ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ch == '_' ||
      ch == '-' ||
      ch == '.'
    }) else {
    raise @domain.BadRequest(
      message="workflow must be a YAML file directly under .github/workflows",
    )
  }
}
