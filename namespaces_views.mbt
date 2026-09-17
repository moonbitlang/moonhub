///|
/// A namespace page for a user: it lists the repositories of that namespace and
/// never shows the team membership and invitation views.
fn render_namespace(
  assets : Map[String, String],
  user : CurrentUser,
  team : TeamSummary,
  repositories : Array[TeamRepository],
  can_manage : Bool,
) -> @moonback.Html {
  layout(
    team.display_name,
    assets,
    Html(b => {
      b <+
        "<section class=\"page-heading\"><div><h1>\{team.display_name}</h1><p class=\"page-subtitle\">@\{team.name_key}</p></div></section>"
      b <+ "\{render_team_repositories(team, repositories, can_manage)}"
    }),
    current_user=Some(user),
    navigation=PersonalNavigation(team),
  )
}
