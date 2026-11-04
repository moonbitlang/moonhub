///|
pub suberror InvalidAction {
  InvalidAction(String)
}

///|
pub struct Reference {
  repository : String
  path : String
  ref_ : String
}

///|
fn valid_path(path : String) -> Bool {
  !path.is_empty() &&
  path.length() <= 512 &&
  !path.has_prefix("/") &&
  !path.contains("\\") &&
  path
  .split("/")
  .all(part => {
    !part.is_empty() &&
    part != "." &&
    part != ".." &&
    part != ".git" &&
    part
    .iter()
    .all(ch => {
      ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ['-', '_', '.'].contains(ch)
    })
  })
}

///|
// Only public GitHub repositories and explicit refs. No URL, credentials,
// shell fragment, ambiguous refspec or implicit default branch is accepted.
pub fn parse_reference(value : String) -> Reference raise InvalidAction {
  if value.strip_prefix("./") is Some(path) {
    guard valid_path(path.to_owned()) else {
      raise InvalidAction("invalid local action path")
    }
    return { repository: "", path: path.to_owned(), ref_: "", }
  }
  guard value.length() <= 1024 &&
    value.split_once("@") is Some((location, ref_)) &&
    !ref_.is_empty() &&
    !ref_.has_prefix("-") &&
    !ref_.contains("@") &&
    ref_.length() <= 200 &&
    !ref_.contains("..") &&
    !ref_.has_prefix("/") &&
    !ref_.has_suffix("/") &&
    !ref_.has_suffix(".") &&
    !ref_.has_suffix(".lock") &&
    ref_.split("/").all(part => !part.is_empty() && !part.has_prefix(".")) &&
    ref_
    .iter()
    .all(ch => {
      ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ['-', '_', '.', '/', '+'].contains(ch)
    }) else {
    raise InvalidAction("uses requires owner/repository[/path]@ref")
  }
  let parts = location.split("/").map(part => part.to_owned()).collect()
  guard parts.length() >= 2 &&
    valid_path(location.to_owned()) &&
    !parts[0].has_prefix("-") &&
    !parts[1].has_prefix("-") else {
    raise InvalidAction("uses requires a public GitHub action reference")
  }
  {
    repository: parts[0] + "/" + parts[1],
    path: parts[2:].join("/"),
    ref_: ref_.to_owned(),
  }
}

///|
pub fn valid_input_name(name : String) -> Bool {
  !name.is_empty() &&
  name.length() <= 100 &&
  name
  .iter()
  .all(ch => {
    ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_' || ch == '-'
  })
}

///|
pub fn input_env(name : String) -> String {
  "INPUT_" + name.to_upper()
}
