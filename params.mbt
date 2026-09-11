///|
fn @moonback.Request::required_param(
  self : @moonback.Request,
  name : String,
  label : String,
) -> String raise AppError {
  match self.params.get(name) {
    Some(value) => value.to_owned()
    None => raise BadRequest(message="missing \{label}")
  }
}

///|
fn @moonback.Request::query_rev(self : @moonback.Request) -> String? {
  self.query().get("rev")
}

///|
fn @moonback.Request::repo_param(
  self : @moonback.Request,
) -> RepoId raise AppError {
  let owner = self.required_param("owner", "repository owner")
  let name = self.required_param("repo", "repository name")
  guard valid_repo_owner(owner) else {
    raise BadRequest(message="invalid repository owner")
  }
  guard valid_segment(name) else {
    raise BadRequest(message="invalid repository name")
  }
  { owner, name, }
}

///|
fn @moonback.Request::rev_param(
  self : @moonback.Request,
) -> String raise AppError {
  let rev = self.required_param("rev", "revision")
  guard valid_repo_path(rev) else {
    raise BadRequest(message="invalid revision")
  }
  rev
}

///|
fn @moonback.Request::commit_param(
  self : @moonback.Request,
) -> String raise AppError {
  let commit = self.required_param("commit", "commit")
  guard valid_segment(commit) else {
    raise BadRequest(message="invalid commit")
  }
  commit
}

///|
fn valid_repo_path(path : String) -> Bool {
  guard !path.is_empty() && !path.contains("\\") else { return false }
  for segment in path.split("/") {
    guard valid_segment(segment.to_owned()) else { return false }
  }
  true
}

///|
fn @moonback.Request::path_param(
  self : @moonback.Request,
) -> String raise AppError {
  let path = self.required_param("path", "path")
  guard valid_repo_path(path) else { raise BadRequest(message="invalid path") }
  path
}
