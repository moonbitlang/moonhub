///|
fn read_permissions(
  value : @yaml.Yaml?,
  inherited : (Bool, Bool),
  ctx : String,
) -> (Bool, Bool) raise InvalidWorkflow {
  guard value is Some(value) else { return inherited }
  let fields = yaml_as_obj(value, ctx)
  check_fields(fields, ["contents", "id-token"], ctx)
  let contents = match fields.get("contents") {
    None | Some(String("none")) => false
    Some(String("read")) => true
    _ => raise InvalidWorkflow("\{ctx}.contents supports only read or none")
  }
  let id_token = match fields.get("id-token") {
    None | Some(String("none")) => false
    Some(String("write")) => true
    _ => raise InvalidWorkflow("\{ctx}.id-token supports only write or none")
  }
  (contents, id_token)
}

///|
fn runner_labels(
  value : @yaml.Yaml?,
  ctx : String,
) -> Array[String] raise InvalidWorkflow {
  let labels = yaml_as_string_list(value, ctx).map(label => label.to_lower())
  if !labels.contains("self-hosted") && labels.length() == 1 {
    let label = labels[0]
    if ["macos-latest", "macos-14", "macos-15"].contains(label) {
      return ["self-hosted", "macos", "arm64", label]
    }
    let os = match label {
      "ubuntu-22.04" | "ubuntu-24.04" | "ubuntu-latest" => "linux"
      "windows-2022" => "windows"
      _ => raise InvalidWorkflow("\{ctx}: unsupported runner environment")
    }
    // The exact environment remains a required provider capability; it is not
    // an alias for every Linux/Windows image or the controller's host OS.
    return ["self-hosted", os, "x64", label]
  }
  labels
}
