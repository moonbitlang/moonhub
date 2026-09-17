///|
/// Resolves the namespace named by the request's owner segment. A namespace is
/// the team row behind a repository owner, whether it is an organization team
/// or the personal namespace of a user.
pub fn require_owner_namespace(
  pool : @database.Database,
  req : @moonback.Request,
) -> @identity.TeamSummary raise {
  let owner = required_param(req, "owner", "namespace")
  guard @domain.valid_repo_owner(owner) else {
    raise @domain.NotFound(message="namespace not found")
  }
  match @identity.get_team_by_name_key(pool, owner) {
    Some(team) => team
    None => raise @domain.NotFound(message="namespace not found")
  }
}

///|
/// Member and invitation views describe an organization team. A user's personal
/// namespace has no such views, so it is never a team here.
pub fn require_organization_namespace(
  pool : @database.Database,
  req : @moonback.Request,
) -> @identity.TeamSummary raise {
  let team = require_owner_namespace(pool, req)
  guard team.kind == "org" else {
    raise @domain.NotFound(message="team not found")
  }
  team
}
