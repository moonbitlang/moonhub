///|
fn render_provider_admin(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  providers : Array[@pipeline.Provider],
  csrf : String,
  token : String?,
  error : String?,
) -> @moonback.Html {
  @web_ui.layout(
    "Pipeline providers",
    assets,
    Html(b => {
      b <+
        "<div class=\"page-heading\"><div><h1>Pipeline providers</h1><p class=\"page-subtitle\">Manage isolated Docker workers and repository grants.</p></div></div>"
      if error is Some(error) {
        b <+
          "<p class=\"flash-error\" role=\"alert\">\{pipeline_html(error)}</p>"
      }
      if token is Some(token) {
        b <+
          "<p class=\"settings-success\" role=\"status\">Provider created. Store this token in the provider secret now; it is not shown again: <code>\{token}</code></p>"
      }
      b <+
        "<section class=\"repository-form\"><h2>Register provider</h2><form class=\"form-stack\" method=\"post\" action=\"/-/admin/pipelines/providers\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><label class=\"field\"><span>Name</span><input name=\"name\" required maxlength=\"64\"></label><label class=\"field\"><span>Labels</span><input name=\"labels\" value=\"self-hosted,linux\" required maxlength=\"512\"><small class=\"muted\">Comma-separated labels. self-hosted and linux are required.</small></label><label class=\"field\"><span>Repositories</span><input name=\"repositories\" maxlength=\"2048\" placeholder=\"alice/demo,bob/service\"><small class=\"muted\">Comma-separated repository paths. Empty means no work is allowed.</small></label><button type=\"submit\">Create provider</button></form></section>"
      b <+ "<section><h2>Registered providers</h2><ul class=\"mr-list\">"
      for provider in providers {
        let state = if provider.revoked {
          "revoked"
        } else if provider.paused {
          "paused"
        } else {
          "active"
        }
        b <+
          "<li><div class=\"mr-list-title\"><strong>\{pipeline_html(provider.name)}</strong><span class=\"mr-state\" data-state=\"\{state}\">\{state}</span></div><p class=\"muted\">#\{provider.id.to_string()} · labels \{pipeline_html(provider.labels.join(", "))}</p><div class=\"mr-actions\">"
        if !provider.revoked {
          b <+
            "<form method=\"post\" action=\"/-/admin/pipelines/providers/\{provider.id.to_string()}/pause\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"paused\" value=\"\{if provider.paused { "0" } else { "1" }}\"><button type=\"submit\">\{if provider.paused { "Resume" } else { "Pause" }}</button></form><form method=\"post\" action=\"/-/admin/pipelines/providers/\{provider.id.to_string()}/revoke\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button class=\"danger-button\" type=\"submit\">Revoke</button></form>"
        }
        b <+ "</div></li>"
      }
      if providers.is_empty() {
        b <+ "<li class=\"muted\">No providers registered.</li>"
      }
      b <+ "</ul></section>"
    }),
    head_end=@web_assets.repository_assets_head(assets),
    current_user=Some(user),
    navigation=@web_ui.SiteNavigation("pipeline-providers"),
  )
}
