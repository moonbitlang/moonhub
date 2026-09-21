///|
fn render_provider_admin(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  providers : Array[@pipeline.Provider],
  csrf : String,
  token : String?,
  error : String?,
  labels_saved? : Bool = false,
  scope_saved? : Bool = false,
  registration? : Map[String, String] = Map([]),
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
      if labels_saved {
        b <+
          "<p class=\"settings-success\" role=\"status\">Provider labels saved.</p>"
      }
      if scope_saved {
        b <+
          "<p class=\"settings-success\" role=\"status\">Provider access saved.</p>"
      }
      if token is Some(token) {
        b <+
          "<p class=\"settings-success\" role=\"status\">Provider created. Store this token in the provider secret now; it is not shown again: <code>\{token}</code></p>"
      }
      b <+
        "<section class=\"repository-form\"><h2>Register provider</h2><form class=\"form-stack\" method=\"post\" action=\"/-/admin/pipelines/providers\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><label class=\"field\"><span>Name</span><input name=\"name\" value=\"\{registration.get("name").unwrap_or("")}\" required maxlength=\"64\"></label><label class=\"field\"><span>Labels</span><input name=\"labels\" value=\"\{registration.get("labels").unwrap_or("self-hosted,linux")}\" required maxlength=\"512\"><small class=\"muted\">Comma-separated labels. self-hosted and linux are required.</small></label>\{render_provider_scope_fields(registration.get("scope").unwrap_or("selected"), registration.get("repositories").unwrap_or(""))}<button type=\"submit\">Create provider</button></form></section>"
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
          "<li><div class=\"mr-list-title\"><strong>\{pipeline_html(provider.name)}</strong><span class=\"mr-state\" data-state=\"\{state}\">\{state}</span></div><p class=\"muted\">#\{provider.id.to_string()} · labels \{pipeline_html(provider.labels.join(", "))}</p>"
        let access = if provider.scope is @pipeline.AllRepositories {
          "All repositories (including new repositories)"
        } else if provider.repositories.is_empty() {
          "Selected repositories: none"
        } else {
          "Selected repositories: " + provider.repositories.join(", ")
        }
        let contact = if provider.last_seen_ms is None {
          "Never connected"
        } else if provider.online {
          "Recent contact"
        } else {
          "No contact in the last minute"
        }
        b <+
          "<p class=\"muted provider-access-summary\">\{access}</p><p class=\"muted\">\{contact}</p><div class=\"mr-actions\">"
        if !provider.revoked {
          b <+
            "<a href=\"/-/admin/pipelines/providers/\{provider.id.to_string()}/labels\" aria-label=\"Edit labels for \{provider.name}\">Edit labels</a>"
          b <+
            "<a href=\"/-/admin/pipelines/providers/\{provider.id.to_string()}/access\" aria-label=\"Edit access for \{provider.name}\">Edit access</a>"
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

///|
fn render_provider_scope_fields(
  scope : String,
  repositories : String,
) -> @moonback.Html {
  Html(b => {
    b <+
      "<div class=\"field\"><label for=\"provider-repository-scope\">Repository scope</label><select id=\"provider-repository-scope\" name=\"scope\"><option value=\"selected\""
    if scope != "all" {
      b <+ " selected"
    }
    b <+ ">Selected repositories</option><option value=\"all\""
    if scope == "all" {
      b <+ " selected"
    }
    b <+
      ">All repositories</option></select></div><label class=\"field\"><span>Repositories (selected scope only)</span><input name=\"repositories\" value=\"\{repositories}\" maxlength=\"2048\" placeholder=\"compiler/moonhub\" spellcheck=\"false\" autocapitalize=\"none\"></label><p class=\"settings-notice\">All repositories includes current and future repositories. Selected repositories with an empty list allows no work.</p>"
  })
}

///|
fn render_provider_access(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  provider : @pipeline.Provider,
  csrf : String,
  scope : String,
  repositories : String,
  error : String?,
) -> @moonback.Html {
  @web_ui.layout(
    "Edit provider access",
    assets,
    Html(b => {
      b <+
        "<section class=\"repository-form\"><a href=\"/-/admin/pipelines/providers\">Pipeline providers</a><h1>Edit provider access</h1><p class=\"page-subtitle\">\{provider.name} · #\{provider.id.to_string()}</p>"
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"/-/admin/pipelines/providers/\{provider.id.to_string()}/access\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\">\{render_provider_scope_fields(scope, repositories)}<p class=\"settings-notice\">Assigned jobs outside the new repository scope will be cancelled, including running jobs. Unassigned jobs remain queued.</p><div class=\"form-actions\"><button type=\"submit\"><span class=\"ui-icon\" data-icon=\"check\" aria-hidden=\"true\"></span>Save access</button><a href=\"/-/admin/pipelines/providers\">Cancel</a></div></form></section>"
    }),
    head_end=@web_assets.repository_assets_head(assets),
    current_user=Some(user),
    navigation=@web_ui.SiteNavigation("pipeline-providers"),
  )
}

///|
fn render_provider_labels(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  provider : @pipeline.Provider,
  csrf : String,
  labels : String,
  error : String?,
) -> @moonback.Html {
  @web_ui.layout(
    "Edit provider labels",
    assets,
    Html(b => {
      b <+
        "<section class=\"repository-form\"><a href=\"/-/admin/pipelines/providers\">Pipeline providers</a><h1>Edit provider labels</h1><p class=\"page-subtitle\">\{provider.name} · #\{provider.id.to_string()}</p>"
      if error is Some(message) {
        b <+
          "<p class=\"flash-error\" id=\"provider-label-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"/-/admin/pipelines/providers/\{provider.id.to_string()}/labels\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><div class=\"field\"><label for=\"provider-labels\">Labels</label><input id=\"provider-labels\" name=\"labels\" value=\"\{labels}\" required maxlength=\"519\" spellcheck=\"false\" autocapitalize=\"none\" aria-describedby=\"provider-label-impact"
      if error is Some(_) {
        b <+ " provider-label-error\" aria-invalid=\"true"
      }
      b <+
        "\"></div><p class=\"settings-notice\" id=\"provider-label-impact\">Jobs that no longer match these labels will be cancelled, including running jobs.</p><div class=\"form-actions\"><button type=\"submit\"><span class=\"ui-icon\" data-icon=\"check\" aria-hidden=\"true\"></span>Save labels</button><a href=\"/-/admin/pipelines/providers\">Cancel</a></div></form></section>"
    }),
    head_end=@web_assets.repository_assets_head(assets),
    current_user=Some(user),
    navigation=@web_ui.SiteNavigation("pipeline-providers"),
  )
}
