///|
fn render_user_ssh_keys(
  assets : Map[String, String],
  user : CurrentUser,
  keys : Array[UserSshKey],
) -> @moonback.Html {
  let active_count = keys.filter(key => key.revoked_at is None).length()
  layout(
    "SSH keys",
    assets,
    Html(b => {
      b <+
        $|<section class="ssh-settings"><div class="page-heading page-heading--actions"><div><h1>SSH keys</h1><p class="ssh-key-count muted">\{active_count.to_string()} active</p></div><a class="button-link" href="/settings/ssh-keys/new">Add SSH key</a></div>
      if keys.is_empty() {
        b <+ "<p class=\"ssh-keys-empty muted\">No SSH keys.</p>"
      } else {
        b <+ "<ul class=\"ssh-key-list\" aria-label=\"Your SSH keys\">"
        for key in keys {
          b <+
            "<li class=\"ssh-key-item\"><div class=\"ssh-key-content\"><div class=\"ssh-key-heading\"><h2>\{key.title}</h2>"
          match key.revoked_at {
            None =>
              b <+
                "<span class=\"ssh-key-state ssh-key-state--active\">Active</span>"
            Some(_) => b <+ "<span class=\"ssh-key-state muted\">Revoked</span>"
          }
          b <+
            "</div><code class=\"ssh-key-fingerprint\">\{key.fingerprint}</code><dl class=\"ssh-key-metadata\"><div><dt>Added</dt><dd>\{key.created_at} UTC</dd></div><div><dt>Last used</dt><dd>"
          match key.last_used_at {
            Some(time) => b <+ "\{time} UTC"
            None => b <+ "Never"
          }
          b <+ "</dd></div>"
          if key.revoked_at is Some(time) {
            b <+ "<div><dt>Revoked</dt><dd>\{time} UTC</dd></div>"
          }
          b <+ "</dl></div>"
          if key.revoked_at is None {
            b <+
              "<a class=\"ssh-revoke-link\" href=\"/settings/ssh-keys/\{key.id.to_string()}/revoke\" aria-label=\"Revoke \{key.title}\">Revoke</a>"
          }
          b <+ "</li>"
        }
        b <+ "</ul>"
      }
      b <+ "</section>"
    }),
    current_user=Some(user),
    navigation=AccountNavigation("ssh-keys"),
  )
}

///|
fn render_new_ssh_key(
  assets : Map[String, String],
  user : CurrentUser,
  csrf_token : String,
  title : String,
  public_key : String,
  error : String?,
) -> @moonback.Html {
  layout(
    "Add SSH key",
    assets,
    Html(b => {
      b <+
        #|<section class="ssh-settings ssh-settings--form"><nav class="ssh-settings-back" aria-label="Settings"><a href="/settings/ssh-keys">SSH keys</a></nav><h1>Add SSH key</h1>
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        $|<form class="form-stack" method="post" action="/settings/ssh-keys"><input type="hidden" name="csrf_token" value="\{csrf_token}"><div class="field"><label for="ssh-key-title"><span>Name</span></label><input id="ssh-key-title" name="title" value="\{title}" maxlength="200" autocomplete="off" required></div><div class="field"><label for="ssh-key-public"><span>Public key (Ed25519)</span></label><textarea id="ssh-key-public" class="ssh-public-key" name="public_key" rows="6" maxlength="16384" autocomplete="off" autocapitalize="none" spellcheck="false" required>\{public_key}</textarea></div><div class="ssh-form-actions"><button type="submit">Add SSH key</button><a href="/settings/ssh-keys">Cancel</a></div></form></section>
    }),
    current_user=Some(user),
    navigation=AccountNavigation("ssh-keys"),
  )
}

///|
fn render_revoke_ssh_key(
  assets : Map[String, String],
  user : CurrentUser,
  csrf_token : String,
  key : UserSshKey,
) -> @moonback.Html {
  layout(
    "Revoke SSH key",
    assets,
    Html(b => {
      b <+
        $|<section class="ssh-settings ssh-settings--form"><nav class="ssh-settings-back" aria-label="Settings"><a href="/settings/ssh-keys">SSH keys</a></nav><h1>Revoke SSH key</h1><div class="ssh-revoke-summary"><h2>\{key.title}</h2><code class="ssh-key-fingerprint">\{key.fingerprint}</code></div><p>This key will no longer authorize new SSH connections or Git operations. Transfers already in progress will continue.</p><p class="muted">Revocation cannot be undone.</p><form method="post" action="/settings/ssh-keys/\{key.id.to_string()}/revoke"><input type="hidden" name="csrf_token" value="\{csrf_token}"><div class="ssh-form-actions"><button class="ssh-danger-button" type="submit">Revoke SSH key</button><a href="/settings/ssh-keys">Cancel</a></div></form></section>
    }),
    current_user=Some(user),
    navigation=AccountNavigation("ssh-keys"),
  )
}
