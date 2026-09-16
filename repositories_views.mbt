///|
fn repository_status_label(status : String, importing : Bool) -> String {
  match status {
    "pending" => "Queued"
    "running" => if importing { "Importing" } else { "Creating" }
    "creating" => "Creating"
    "failed" => "Failed"
    _ => "Ready"
  }
}

///|
fn render_team_repositories(
  team : TeamSummary,
  repos : Array[TeamRepository],
  can_manage : Bool,
) -> @moonback.Html {
  Html(b => {
    b <+
      "<section class=\"team-repositories\"><div class=\"repository-section-heading\"><h2>Repositories</h2>"
    if can_manage {
      b <+
        "<div class=\"repository-actions\"><a href=\"/teams/\{team.name_key}/repositories/import\">Import via SSH</a><a class=\"button-link\" href=\"/teams/\{team.name_key}/repositories/new\">New repository</a></div>"
    }
    b <+ "</div><ul class=\"team-repository-list\">"
    if repos.is_empty() {
      b <+ "<li class=\"muted\">No repositories.</li>"
    }
    for repo in repos {
      let href = if repo.ready {
        "/\{team.name_key}/\{repo.name}"
      } else {
        "/teams/\{team.name_key}/repositories/\{repo.name}/status"
      }
      b <+
        "<li><a class=\"repo-name path\" href=\"\{href}\">\{repo.name}</a><span class=\"repository-visibility muted\">\{repo.visibility}</span>"
      if !repo.ready {
        b <+
          "<span class=\"repository-state\">\{repository_status_label(repo.status.unwrap_or("pending"), true)}</span>"
      }
      b <+ "</li>"
    }
    b <+ "</ul></section>"
  })
}

///|
fn render_repository_form(
  assets : Map[String, String],
  user : CurrentUser,
  team : TeamSummary,
  csrf : String,
  importing : Bool,
  import_available : Bool,
  name : String,
  visibility : String,
  source : String,
  error : String?,
) -> @moonback.Html {
  let title = if importing { "Import repository" } else { "New repository" }
  let action = if importing {
    "/teams/\{team.name_key}/repositories/import"
  } else {
    "/teams/\{team.name_key}/repositories"
  }
  layout(
    title,
    assets,
    Html(b => {
      b <+
        "<section class=\"repository-form\"><nav class=\"ssh-settings-back\" aria-label=\"Team\"><a href=\"/teams/\{team.name_key}\">\{team.display_name}</a></nav><h1>\{title}</h1><nav class=\"repository-mode\" aria-label=\"Repository source\">"
      if importing {
        b <+
          "<a href=\"/teams/\{team.name_key}/repositories/new\">Empty repository</a><a href=\"/teams/\{team.name_key}/repositories/import\" aria-current=\"page\">SSH import</a>"
      } else {
        b <+
          "<a href=\"/teams/\{team.name_key}/repositories/new\" aria-current=\"page\">Empty repository</a><a href=\"/teams/\{team.name_key}/repositories/import\">SSH import</a>"
      }
      b <+ "</nav>"
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      if importing && !import_available {
        b <+
          "<p class=\"flash-error\" role=\"status\">SSH imports are not configured for this team.</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"\{action}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><div class=\"field\"><label for=\"repository-name\"><span>Repository name</span></label><div class=\"repository-name-field\"><span class=\"path muted\">\{team.name_key}/</span><input id=\"repository-name\" name=\"name\" value=\"\{name}\" maxlength=\"100\" autocomplete=\"off\" required></div></div><div class=\"field\"><label for=\"repository-visibility\"><span>Visibility</span></label><select id=\"repository-visibility\" name=\"visibility\">"
      if visibility == "public" {
        b <+
          "<option value=\"private\">Private</option><option value=\"public\" selected>Public</option>"
      } else {
        b <+
          "<option value=\"private\" selected>Private</option><option value=\"public\">Public</option>"
      }
      b <+ "</select></div>"
      if importing {
        b <+
          "<div class=\"field\"><label for=\"repository-source\"><span>Source SSH URL</span></label><input id=\"repository-source\" class=\"path\" name=\"source_url\" value=\"\{source}\" maxlength=\"2048\" autocomplete=\"off\" spellcheck=\"false\" required></div>"
      }
      b <+ "<div class=\"repository-actions\">"
      if importing && !import_available {
        b <+ "<button type=\"submit\" disabled>Import repository</button>"
      } else {
        b <+
          "<button type=\"submit\">\{if importing { "Import repository" } else { "Create repository" }}</button>"
      }
      b <+
        "<a href=\"/teams/\{team.name_key}\">Cancel</a></div></form></section>"
    }),
    current_user=Some(user),
  )
}

///|
fn render_repository_job(
  assets : Map[String, String],
  user : CurrentUser,
  team : TeamSummary,
  job : RepositoryJob,
  csrf : String,
  can_manage : Bool,
  discarding : Bool,
) -> @moonback.Html {
  layout(
    job.repo.path(),
    assets,
    Html(b => {
      b <+
        "<section class=\"repository-form\"><nav class=\"ssh-settings-back\" aria-label=\"Team\"><a href=\"/teams/\{team.name_key}\">\{team.display_name}</a></nav>"
      if discarding {
        b <+
          "<h1>Discard failed operation</h1><p class=\"path\">\{job.repo.path()}</p>"
      } else {
        b <+
          "<h1 class=\"path\">\{job.repo.path()}</h1><p class=\"repository-job-state\" role=\"status\">\{repository_status_label(job.status, !job.source_url.is_empty())}</p>"
      }
      if !job.source_url.is_empty() {
        b <+
          "<dl class=\"repository-job-details\"><dt>SSH source</dt><dd class=\"path\">\{job.source_url}</dd></dl>"
      }
      b <+ "<p class=\"muted\">Attempts: \{job.attempt_count.to_string()}</p>"
      if job.last_error is Some(_) {
        b <+ "<p class=\"repository-job-error\">\{repository_error_message}</p>"
      }
      if discarding {
        b <+
          "<p>The reserved repository name will be released. No existing repository data will be deleted.</p><form method=\"post\" action=\"/teams/\{team.name_key}/repositories/\{job.repo.name}/discard\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><div class=\"repository-actions\"><button class=\"danger-button\" type=\"submit\">Discard operation</button><a href=\"/teams/\{team.name_key}/repositories/\{job.repo.name}/status\">Cancel</a></div></form>"
      } else if job.status == "failed" && can_manage {
        b <+
          "<form method=\"post\" action=\"/teams/\{team.name_key}/repositories/\{job.repo.name}/retry\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><div class=\"repository-actions\"><button type=\"submit\">Retry</button><a class=\"ssh-revoke-link\" href=\"/teams/\{team.name_key}/repositories/\{job.repo.name}/discard\">Discard failed operation</a></div></form>"
      }
      b <+ "</section>"
    }),
    current_user=Some(user),
  )
}
