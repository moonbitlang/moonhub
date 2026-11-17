///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) struct Definition {
  name : String
  selector : String
  architecture : String
  image : String
  labels : Array[String]
}

///|
#derive(Debug, ToJson, FromJson)
pub(all) struct Profile {
  id : String
  environment : Definition
  is_default : Bool
}

///|
#derive(ToJson, FromJson)
pub(all) struct Probe {
  environment_protocol : Int32
  os_release : String
  architecture : String
}

///|
pub extend Probe with ToJson::{to_json}

///|
pub extend Probe with @json.FromJson::{from_json}

///|
pub extend Definition with @debug.Debug::{to_repr}

///|
pub extend Definition with Eq::{equal, not_equal}

///|
pub extend Definition with ToJson::{to_json}

///|
pub extend Definition with @json.FromJson::{from_json}

///|
pub extend Profile with @debug.Debug::{to_repr}

///|
pub extend Profile with ToJson::{to_json}

///|
pub extend Profile with @json.FromJson::{from_json}

///|
pub let selectors : Array[String] = [
  "debian-12", "ubuntu-22.04", "ubuntu-24.04",
]

///|
pub fn is_environment_label(label : String) -> Bool {
  label.has_prefix("ubuntu-") ||
  label.has_prefix("debian-") ||
  label == "x64" ||
  label == "arm64"
}

///|
pub fn image_digest(image : String) -> String? {
  guard image.length() <= 256 &&
    image.split_once("@sha256:") is Some((repository, digest)) &&
    !repository.is_empty() &&
    !repository.contains("://") &&
    repository
    .iter()
    .all(c => {
      c.is_ascii_alphabetic() ||
      c.is_ascii_digit() ||
      c == '.' ||
      c == '/' ||
      c == '_' ||
      c == ':' ||
      c == '-'
    }) &&
    repository.iter().next() is Some(first) &&
    (first.is_ascii_alphabetic() || first.is_ascii_digit()) &&
    digest.length() == 64 &&
    digest.iter().all(c => c.is_ascii_digit() || (c >= 'a' && c <= 'f')) else {
    return None
  }
  Some(digest.to_owned())
}

///|
pub fn Definition::effective_labels(self : Definition) -> Array[String] {
  let result = [self.selector, self.architecture]
  for label in [self.name] + self.labels {
    if !result.contains(label) {
      result.push(label)
    }
  }
  result
}

///|
pub fn validate_definition(value : Definition) -> String? {
  if value.name.is_empty() ||
    value.name.length() > 64 ||
    !(value.name.iter().next() is Some(first) &&
    (first.is_ascii_digit() || (first >= 'a' && first <= 'z'))) ||
    !value.name
    .iter()
    .all(c => {
      c.is_ascii_digit() || (c >= 'a' && c <= 'z') || c == '-' || c == '.'
    }) ||
    ["self-hosted", "linux", "windows", "macos", "x64", "arm64"].contains(
      value.name,
    ) {
    return Some(
      "Environment names must start with a lowercase letter or digit and use up to 64 lowercase letters, digits, dots or hyphens.",
    )
  }
  if !selectors.contains(value.selector) ||
    !["x64", "arm64"].contains(value.architecture) {
    return Some("Choose a supported Linux distribution and architecture.")
  }
  if is_environment_label(value.name) && value.name != value.selector {
    return Some("The environment name conflicts with its distribution.")
  }
  if value.name.has_prefix("windows-") || value.name.has_prefix("macos-") {
    return Some(
      "Linux environment names cannot declare another operating system.",
    )
  }
  if image_digest(value.image) is None {
    return Some(
      "Use an immutable runner image ending in @sha256: and its 64-character lowercase digest.",
    )
  }
  if value.labels.length() > 16 {
    return Some("Each environment supports at most 16 additional labels.")
  }
  let seen : Map[String, Bool] = Map([])
  for label in value.labels {
    if label.is_empty() ||
      label.length() > 64 ||
      !label
      .iter()
      .all(c => {
        c.is_ascii_digit() ||
        (c >= 'a' && c <= 'z') ||
        c == '-' ||
        c == '_' ||
        c == '.'
      }) ||
      seen.contains(label) ||
      label.has_prefix("windows-") ||
      label.has_prefix("macos-") ||
      ["self-hosted", "linux", "windows", "macos"].contains(label) ||
      (
        is_environment_label(label) &&
        label != value.selector &&
        label != value.architecture &&
        !(label == "ubuntu-latest" && value.selector.has_prefix("ubuntu-"))
      ) {
      return Some(
        "Environment labels must be unique lowercase capability labels and cannot contradict the distribution or architecture.",
      )
    }
    seen[label] = true
  }
  None
}

///|
pub fn validate_set(
  values : Array[Definition],
  default_name : String,
) -> String? {
  if values.length() > 8 {
    return Some("A provider supports at most eight Linux environments.")
  }
  if values.is_empty() {
    return if default_name.is_empty() {
      None
    } else {
      Some("Choose a default from the saved environments.")
    }
  }
  let names : Map[String, Bool] = Map([])
  for value in values {
    if validate_definition(value) is Some(message) {
      return Some(message)
    }
    if names.contains(value.name) {
      return Some("Environment names must be unique within a provider.")
    }
    if value.architecture != values[0].architecture {
      return Some(
        "All environments in a provider must use the same architecture.",
      )
    }
    names[value.name] = true
  }
  if !names.contains(default_name) {
    return Some("Choose one default environment for generic Linux jobs.")
  }
  None
}

///|
pub fn Definition::matches_system(
  self : Definition,
  os_release : String,
  architecture : String,
) -> Bool {
  let architecture = match architecture.trim().to_owned() {
    "x86_64" | "amd64" => "x64"
    "aarch64" => "arm64"
    value => value
  }
  guard architecture == self.architecture &&
    self.selector.split_once("-") is Some((distribution, version)) else {
    return false
  }
  let fields : Map[String, String] = Map([])
  for line in os_release.split("\n") {
    if line.split_once("=") is Some((key, value)) {
      fields[key.to_owned()] = value.trim().trim(chars="\"'").to_owned()
    }
  }
  fields.get("ID") == Some(distribution.to_owned()) &&
  fields.get("VERSION_ID") == Some(version.to_owned())
}
