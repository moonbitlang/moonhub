///|
fn render_deploy_keys(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  repo : @domain.RepoId,
  keys : Array[@ssh.DeployKey],
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(repo)}/settings/deploy-keys"
  let active = keys.filter(key => key.revoked_at is None).length().to_string()
  @web_ui.layout(
    "Deploy keys",
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings\"><div class=\"page-heading page-heading--actions\"><div><h1>Deploy keys</h1><p class=\"ssh-key-count muted\">\{active} active</p></div><a class=\"button-link\" href=\"\{base}/new\"><span class=\"ui-icon\" data-icon=\"plus\" aria-hidden=\"true\"></span>Add deploy key</a></div>"
      if keys.is_empty() {
        b <+ "<p class=\"ssh-keys-empty muted\">No deploy keys.</p>"
      } else {
        b <+ "<ul class=\"ssh-key-list\" aria-label=\"Repository deploy keys\">"
        for key in keys {
          let id = key.id.to_string()
          b <+
            "<li class=\"ssh-key-item\"><div class=\"ssh-key-content\"><div class=\"ssh-key-heading\"><h2>\{key.title}</h2>"
          if key.revoked_at is None {
            b <+
              "<span class=\"ssh-key-state ssh-key-state--active\">Active</span>"
          } else {
            b <+ "<span class=\"ssh-key-state muted\">Revoked</span>"
          }
          b <+
            "<span class=\"ssh-key-state\">\{if key.write_access { "Read / write" } else { "Read-only" }}</span></div><code class=\"ssh-key-fingerprint\">\{key.fingerprint}</code><dl class=\"ssh-key-metadata\"><div><dt>Added by</dt><dd>\{key.creator}</dd></div><div><dt>Added</dt><dd>\{key.created_at} UTC</dd></div><div><dt>Last used</dt><dd>\{key.last_used_at.map(time => time + " UTC").unwrap_or("Never")}</dd></div>"
          if key.revoked_at is Some(time) {
            b <+ "<div><dt>Revoked</dt><dd>\{time} UTC</dd></div>"
          }
          b <+ "</dl>"
          if key.revoked_at is None {
            b <+
              "<div class=\"ssh-form-actions\"><a href=\"\{base}/\{id}/access\" aria-label=\"Edit access for \{key.title}\">Edit access</a><a class=\"ssh-revoke-link\" href=\"\{base}/\{id}/revoke\" aria-label=\"Revoke \{key.title}\">Revoke</a></div>"
          }
          b <+ "</div></li>"
        }
        b <+ "</ul>"
      }
      b <+ "</section>"
    }),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(repo, "deploy-keys", true),
  )
}

///|
fn render_new_deploy_key(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  repo : @domain.RepoId,
  csrf_token : String,
  title : String,
  public_key : String,
  write_access : Bool,
  error : String?,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(repo)}/settings/deploy-keys"
  @web_ui.layout(
    "Add deploy key",
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings ssh-settings--form\"><nav class=\"ssh-settings-back\" aria-label=\"Settings\"><a href=\"\{base}\">Deploy keys</a></nav><h1>Add deploy key</h1>"
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"\{base}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf_token}\"><div class=\"field\"><label for=\"deploy-key-title\">Name</label><input id=\"deploy-key-title\" name=\"title\" value=\"\{title}\" maxlength=\"200\" autocomplete=\"off\" required></div><div class=\"field\"><label for=\"deploy-key-public\">Public key (Ed25519)</label><textarea id=\"deploy-key-public\" class=\"ssh-public-key\" name=\"public_key\" rows=\"6\" maxlength=\"16384\" autocomplete=\"off\" autocapitalize=\"none\" spellcheck=\"false\" required>\{public_key}</textarea></div><label class=\"checkbox-field\"><input type=\"checkbox\" name=\"write_access\" value=\"1\""
      if write_access {
        b <+ " checked"
      }
      b <+
        "><span>Allow write access</span></label><div class=\"ssh-form-actions\"><button type=\"submit\">Add deploy key</button><a href=\"\{base}\">Cancel</a></div></form></section>"
    }),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(repo, "deploy-keys", true),
  )
}

///|
fn render_deploy_key_action(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  repo : @domain.RepoId,
  csrf_token : String,
  key : @ssh.DeployKey,
  action : String,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(repo)}/settings/deploy-keys"
  let heading = if action == "revoke" {
    "Revoke deploy key"
  } else {
    "Edit deploy key access"
  }
  let id = key.id.to_string()
  @web_ui.layout(
    heading,
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings ssh-settings--form\"><nav class=\"ssh-settings-back\" aria-label=\"Settings\"><a href=\"\{base}\">Deploy keys</a></nav><h1>\{heading}</h1><div class=\"ssh-revoke-summary\"><h2>\{key.title}</h2><code class=\"ssh-key-fingerprint\">\{key.fingerprint}</code></div>"
      if action == "revoke" {
        b <+ "<p>Revoke this key for \{repo.path()}? This cannot be undone.</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"\{base}/\{id}/\{action}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf_token}\">"
      if action == "access" {
        b <+
          "<label class=\"checkbox-field\"><input type=\"checkbox\" name=\"write_access\" value=\"1\""
        if key.write_access {
          b <+ " checked"
        }
        b <+ "><span>Allow write access</span></label>"
      }
      b <+ "<div class=\"ssh-form-actions\"><button type=\"submit\""
      if action == "revoke" {
        b <+ " class=\"ssh-danger-button\""
      }
      b <+
        ">\{if action == "revoke" { "Revoke deploy key" } else { "Save access" }}</button><a href=\"\{base}\">Cancel</a></div></form></section>"
    }),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(repo, "deploy-keys", true),
  )
}
