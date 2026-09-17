///|
/// A namespace page for a user: it lists the repositories of that namespace and
/// never shows the team membership and invitation views.
fn render_namespace(
  assets : Map[String, String],
  user : @domain.CurrentUser,
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
    current_user=Some(user),
    navigation=@web_ui.PersonalNavigation(team),
  )
}
