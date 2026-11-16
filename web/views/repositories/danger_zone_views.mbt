///|
fn render_danger_zone(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  settings : @repository.RepositorySettings,
  action : String,
  token : String,
  confirmation~ : String = "",
  error~ : String? = None,
) -> @moonback.Html {
  let repo = settings.scope.repo
  let base = "\{@web_ui.repo_link(repo)}/settings/danger-zone"
  let target = if settings.visibility == "private" {
    "public"
  } else {
    "private"
  }
  let title = match action {
    "visibility" => "Change repository visibility"
    "delete" => "Delete repository"
    _ => "Danger Zone"
  }
  @web_ui.layout(
    title,
    assets,
    Html(b => {
      b <+ "<section class=\"ssh-settings danger-zone\">"
      if action != "" {
        b <+
          "<nav class=\"ssh-settings-back\" aria-label=\"Settings\"><a href=\"\{base}\">Danger Zone</a></nav>"
      }
      b <+ "<h1>\{title}</h1>"
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      if action == "" {
        b <+
          "<div class=\"danger-zone-panel\"><div class=\"danger-zone-row\"><div><h2>Repository visibility</h2><p>This repository is currently <strong>\{settings.visibility}</strong>.</p></div><a class=\"button-link danger-button secondary-button\" href=\"\{base}/visibility\">Change visibility</a></div><div class=\"danger-zone-row\"><div><h2>Delete this repository</h2><p>Permanently delete this repository and its associated data. This cannot be undone.</p></div><a class=\"button-link danger-button secondary-button\" href=\"\{base}/delete\">Delete repository</a></div></div>"
      } else {
        if action == "visibility" {
          b <+
            "<p>Change <strong>\{repo.path()}</strong> from <strong>\{settings.visibility}</strong> to <strong>\{target}</strong>?</p>"
          if target == "public" {
            b <+
              "<p>Anyone, including people who are not signed in, will be able to view the repository, code, issues, pull requests, Actions and published releases. Write access will still require membership.</p>"
          } else {
            b <+
              "<p>Only members of the owning space and site administrators will be able to access this repository. Anonymous visitors and other users will lose access. Existing copies and previously downloaded files cannot be recalled.</p>"
          }
        } else {
          b <+
            "<p>Permanently delete <strong>\{repo.path()}</strong>? This cannot be undone.</p><ul><li>Code, branches, tags, issues, pull requests, reviews and notifications will be deleted.</li><li>Actions history, artifacts, caches, releases and attachments will be deleted.</li><li>Secrets, variables, webhooks, mirrors and repository settings will be deleted. Deploy keys will be revoked.</li><li>The repository becomes inaccessible immediately. Stored files are removed in the background.</li></ul><p>Cancel unfinished Actions and wait for mirror syncs and webhook deliveries to finish before deleting.</p>"
        }
        b <+
          "<form class=\"form-stack\" method=\"post\" action=\"\{base}/\{action}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{token}\"><input type=\"hidden\" name=\"repository_id\" value=\"\{settings.scope.id.to_string()}\">"
        if action == "visibility" {
          b <+
            "<input type=\"hidden\" name=\"previous\" value=\"\{settings.visibility}\"><input type=\"hidden\" name=\"visibility\" value=\"\{target}\">"
        } else {
          b <+
            "<div class=\"field\"><label for=\"repository-confirmation\">Type \{repo.path()} to confirm</label><input id=\"repository-confirmation\" name=\"confirmation\" value=\"\{confirmation}\" autocomplete=\"off\" autocapitalize=\"none\" spellcheck=\"false\" required></div>"
        }
        b <+
          "<div class=\"ssh-form-actions\"><button class=\"danger-button\" type=\"submit\">\{if action == "visibility" { "Confirm visibility change" } else { "Delete this repository" }}</button><a href=\"\{base}\">Cancel</a></div></form>"
      }
      b <+ "</section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "danger-zone", true),
  )
}
