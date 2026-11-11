///|
/// Repository discovery for personal namespaces and anonymous visitors. Team
/// membership and invitations belong to the authenticated team view.
fn render_namespace(
  assets : Map[String, String],
  user : @domain.CurrentUser?,
  team : @identity.TeamSummary,
  repositories : Array[@repository.TeamRepository],
  can_manage : Bool,
) -> @moonback.Html {
  @web_ui.layout(
    team.display_name,
    assets,
    Html(b => {
      b <+
        "<section class=\"page-heading\"><div><h1>\{team.display_name}</h1><p class=\"page-subtitle\">@\{team.name_key}</p></div></section>"
      b <+ "\{@web_ui.render_team_repositories(team, repositories, can_manage)}"
    }),
    current_user=user,
    navigation=@web_ui.PersonalNavigation(team),
  )
}
