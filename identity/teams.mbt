///|
/// Accepts any member of the namespace, or a site administrator.
pub fn require_team_member_access(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  team : TeamSummary,
) -> Unit raise {
  if actor.is_site_admin {
    ()
  } else {
    match team_role(pool, actor, team.id) {
      Some(_) => ()
      None => raise @domain.Forbidden(message="team access required")
    }
  }
}
