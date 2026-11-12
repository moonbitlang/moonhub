///|
fn render_repository_settings(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  csrf : String,
  confirmation : String,
  error : String?,
) -> @moonback.Html {
  let repo = scope.repo
  @web_ui.layout(
    "Settings",
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings ssh-settings--form\"><h1>Settings</h1><h2>Delete repository</h2>"
      b <+
        "<p>Permanently delete <strong>\{repo.path()}</strong>? This cannot be undone. There is no recovery period.</p><p>Deletion includes all Git history, Issues, merge requests, comments, CI records and logs, attachments, artifacts, caches and repository configuration. Deploy keys will be revoked and webhook delivery will stop.</p><p>Cancel active CI tasks and wait for any mirror sync to finish before deleting.</p>"
      if error is Some(message) {
        b <+ "<p class=\"form-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"\{@web_ui.repo_link(repo)}/settings/delete\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"repository_id\" value=\"\{scope.id.to_string()}\"><label class=\"field\"><span>Type \{repo.path()} to confirm</span><input name=\"confirmation\" value=\"\{confirmation}\" autocomplete=\"off\" required></label><div class=\"ssh-form-actions\"><button class=\"ssh-danger-button\" type=\"submit\">Permanently delete repository</button><a href=\"\{@web_ui.repo_link(repo)}\">Cancel</a></div></form></section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "general-settings", true),
  )
}
