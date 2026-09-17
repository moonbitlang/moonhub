///|
pub fn valid_repo_path(path : String) -> Bool {
  guard !path.is_empty() && !path.contains("\\") else { return false }
  for segment in path.split("/") {
    guard valid_segment(segment.to_owned()) else { return false }
  }
  true
}

///|
pub fn parse_transport_repo(path : String) -> RepoId raise {
  let path = path.strip_prefix("/").unwrap_or(path[:])
  let parts = path.split("/").collect()
  guard parts.length() == 2 else {
    raise BadRequest(message="expected owner/repository.git")
  }
  let owner = parts[0].to_owned()
  let name = parts[1].strip_suffix(".git").unwrap_or(parts[1]).to_owned()
  guard valid_name_key(owner) && !name.is_empty() && name.length() <= 100 else {
    raise BadRequest(message="invalid repository name")
  }
  for i, ch in name {
    let alphanumeric = ch.is_ascii_alphabetic() || ch.is_ascii_digit()
    guard alphanumeric || (i > 0 && (ch == '-' || ch == '_' || ch == '.')) else {
      raise BadRequest(message="invalid repository name")
    }
  }
  { owner, name, }
}
