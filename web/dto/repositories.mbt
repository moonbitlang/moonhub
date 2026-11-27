///|
pub fn repository_json(details : @domain.RepositoryDetails) -> Json {
  {
    "owner": details.repo.owner,
    "name": details.repo.name,
    "full_name": details.repo.path(),
    "visibility": details.visibility,
    "state": details.state,
    "default_branch": details.default_branch
    .map(Json::string)
    .unwrap_or(Json::null()),
    "clone_url": details.clone_url.map(Json::string).unwrap_or(Json::null()),
  }
}
