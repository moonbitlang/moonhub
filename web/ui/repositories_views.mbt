///|
pub fn repository_status_label(status : String, importing : Bool) -> String {
  match status {
    "pending" => "Queued"
    "running" => if importing { "Importing" } else { "Creating" }
    "creating" => "Creating"
    "failed" => "Failed"
    _ => "Ready"
  }
}

///|
pub fn render_team_repositories(
  team : @identity.TeamSummary,
  repos : Array[@repository.TeamRepository],
  can_manage : Bool,
) -> @moonback.Html {
  Html(b => {
    b <+
      "<section class=\"team-repositories\"><div class=\"repository-section-heading\"><h2>Repositories</h2>"
    if can_manage {
      b <+
        "<div class=\"repository-actions\"><a class=\"button-link secondary-button\" href=\"/\{team.name_key}/-/repositories/import\"><span class=\"ui-icon\" data-icon=\"download\" aria-hidden=\"true\"></span>Import via SSH</a><a class=\"button-link\" href=\"/\{team.name_key}/-/repositories/new\"><span class=\"ui-icon\" data-icon=\"plus\" aria-hidden=\"true\"></span>New repository</a></div>"
    }
    b <+ "</div><ul class=\"team-repository-list\">"
    if repos.is_empty() {
      b <+ "<li class=\"muted\">No repositories.</li>"
    }
    for repo in repos {
      let href = if repo.ready {
        "/\{team.name_key}/\{repo.name}"
      } else {
        "/\{team.name_key}/-/repositories/\{repo.name}/status"
      }
      b <+
        "<li><span class=\"repository-icon\"><span class=\"ui-icon\" data-icon=\"book-open\" aria-hidden=\"true\"></span></span><a class=\"repo-name\" href=\"\{href}\">\{repo.name}</a><span class=\"repository-visibility\"><span class=\"ui-icon\" data-icon=\"\{if repo.visibility == "private" { "lock" } else { "globe" }}\" aria-hidden=\"true\"></span>\{repo.visibility}</span>"
      if !repo.ready {
        b <+
          "<span class=\"repository-state\">\{repository_status_label(repo.status.unwrap_or("pending"), true)}</span>"
      }
      b <+ "</li>"
    }
    b <+ "</ul></section>"
  })
}
