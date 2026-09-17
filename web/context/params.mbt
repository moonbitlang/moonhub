///|
pub fn required_param(
  req : @moonback.Request,
  name : String,
  label : String,
) -> String raise @domain.AppError {
  match req.params.get(name) {
    Some(value) => value.to_owned()
    None => raise @domain.BadRequest(message="missing \{label}")
  }
}

///|
pub fn query_rev(req : @moonback.Request) -> String? {
  req.query().get("rev")
}

///|
pub fn repo_param(
  req : @moonback.Request,
) -> @domain.RepoId raise @domain.AppError {
  let owner = required_param(req, "owner", "repository owner")
  let name = required_param(req, "repo", "repository name")
  guard @domain.valid_repo_owner(owner) else {
    raise @domain.BadRequest(message="invalid repository owner")
  }
  guard @domain.valid_repo_name(name) else {
    raise @domain.BadRequest(message="invalid repository name")
  }
  { owner, name, }
}

///|
pub fn rev_param(req : @moonback.Request) -> String raise @domain.AppError {
  let rev = required_param(req, "rev", "revision")
  guard @domain.valid_repo_path(rev) else {
    raise @domain.BadRequest(message="invalid revision")
  }
  rev
}

///|
pub fn commit_param(req : @moonback.Request) -> String raise @domain.AppError {
  let commit = required_param(req, "commit", "commit")
  guard @domain.valid_segment(commit) else {
    raise @domain.BadRequest(message="invalid commit")
  }
  commit
}

///|
pub fn path_param(req : @moonback.Request) -> String raise @domain.AppError {
  let path = required_param(req, "path", "path")
  guard @domain.valid_repo_path(path) else {
    raise @domain.BadRequest(message="invalid path")
  }
  path
}

///|
// Preserve the existing error text used by issue and merge request forms.
pub fn positive_resource_number(value : String) -> Int64 raise {
  let number = @string.parse_int64(value) catch {
    _ => raise @domain.BadRequest(message="invalid merge request number")
  }
  guard number > 0L else {
    raise @domain.BadRequest(message="invalid merge request number")
  }
  number
}
