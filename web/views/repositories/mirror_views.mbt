///|
fn mirror_status(status : String) -> String {
  match status {
    "pending" => "Queued"
    "syncing" => "Syncing"
    "succeeded" => "Up to date"
    "disabled" => "Disabled"
    _ => "Failed"
  }
}

///|
fn render_mirrors(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  mirrors : Array[@repository.PushMirror],
  csrf : String,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(repo)}/settings/mirrors"
  @web_ui.layout(
    "Push mirrors",
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings mirror-settings\"><div class=\"page-heading page-heading--actions\"><div><h1>Push mirrors</h1><p class=\"muted\">Keep another remote up to date with this repository.</p></div><a class=\"button-link\" href=\"\{base}/new\">Add mirror</a></div><p>After a push or merge, MoonHub syncs all branches and tags in the background. Enabling a mirror also syncs existing refs.</p>"
      if mirrors.is_empty() {
        b <+
          "<p class=\"ssh-keys-empty muted\">No push mirrors yet. Add an SSH destination, such as a GitHub repository, to start syncing.</p>"
      } else {
        b <+ "<ul class=\"ssh-key-list\" aria-label=\"Push mirrors\">"
        for mirror in mirrors {
          b <+
            "<li class=\"ssh-key-item\"><div class=\"ssh-key-content\"><div class=\"ssh-key-heading\"><h2><a href=\"\{base}/\{mirror.id.to_string()}\">\{mirror.url}</a></h2><span class=\"ssh-key-state\">\{mirror_status(mirror.status)}</span></div><p class=\"muted\">Branches and tags · Force updates: \{if mirror.force_push {"allowed"} else {"off"}} · Delete remote refs: \{if mirror.prune {"on"} else {"off"}}</p>"
          if mirror.last_success_at is Some(time) {
            b <+
              "<p class=\"muted\">Last successful sync: \{@web_ui.timestamp(time)}</p>"
          } else {
            b <+ "<p class=\"muted\">No successful sync yet.</p>"
          }
          if !mirror.error.is_empty() {
            b <+ "<p role=\"status\">\{mirror.error}</p>"
            if mirror.status == "pending" {
              b <+
                "<p class=\"muted\">Retry scheduled: \{@web_ui.timestamp(mirror.next_attempt_at)} · Attempt \{mirror.attempts.to_string()} of 5</p>"
            }
          }
          b <+
            "<div class=\"ssh-form-actions\"><a href=\"\{base}/\{mirror.id.to_string()}\">Settings and history</a>"
          if mirror.active && mirror.status != "syncing" {
            b <+
              "<form method=\"post\" action=\"\{base}/\{mirror.id.to_string()}/sync\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{mirror.version.to_string()}\"><button type=\"submit\">Sync now</button></form>"
          }
          b <+ "</div></div></li>"
        }
        b <+ "</ul>"
      }
      b <+
        "<p class=\"muted\">Sync failures do not interrupt incoming pushes. Failed syncs receive up to five attempts; you can also retry with Sync now. Reload to see the latest status.</p></section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "mirrors", true),
  )
}

///|
fn render_mirror_form(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  mirror : @repository.PushMirror,
  history : Array[@repository.MirrorAttempt],
  csrf : String,
  error : String?,
  destination_saved~ : Bool = true,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(repo)}/settings/mirrors"
  let title = if mirror.id == 0L {
    "Add push mirror"
  } else {
    "Mirror settings"
  }
  let action = if mirror.id == 0L {
    base
  } else {
    base + "/" + mirror.id.to_string()
  }
  @web_ui.layout(
    title,
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings ssh-settings--form mirror-settings\"><nav class=\"ssh-settings-back\" aria-label=\"Settings\"><a href=\"\{base}\">Push mirrors</a></nav><h1>\{title}</h1><p class=\"muted\">Push this repository’s branches and tags to another remote.</p>"
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      if !mirror.public_key.is_empty() {
        b <+
          "<section class=\"mirror-identity\" aria-labelledby=\"mirror-identity-title\"><h2 id=\"mirror-identity-title\">SSH authentication</h2><p>Add this mirror’s public key to the destination repository as a deploy key with write access. Confirm the destination’s host fingerprint before enabling automatic sync.</p><div class=\"field\"><label for=\"mirror-public-key\">Public key</label><textarea id=\"mirror-public-key\" class=\"ssh-public-key\" rows=\"3\" readonly spellcheck=\"false\" aria-describedby=\"mirror-key-help\">\{mirror.public_key}</textarea><p id=\"mirror-key-help\" class=\"muted\">This key is used only by this mirror. The private key is stored on the server and is never displayed.</p></div></section>"
      } else {
        b <+
          "<p class=\"settings-notice\">Save this mirror to generate its own SSH key. Next, initialize the destination and confirm its host fingerprint, then add the deploy key and enable sync.</p>"
      }
      if mirror.id != 0L && destination_saved {
        b <+
          "<section class=\"mirror-identity\" aria-labelledby=\"mirror-host-title\"><h2 id=\"mirror-host-title\">Destination host verification</h2><p>Saved destination: <strong>\{mirror.url}</strong></p>"
        if !mirror.host_keys.is_empty() {
          b <+
            "<p role=\"status\">Host key trusted. Add the deploy key at the destination, then enable automatic sync.</p><p>Trusted Ed25519 host fingerprint:</p>"
          for
            fingerprint in @repository.mirror_host_fingerprints(
              mirror.host_keys,
            ) {
            b <+
              "<p><code class=\"ssh-key-fingerprint\">\{fingerprint}</code></p>"
          }
        }
        if mirror.host_check is Some(check) {
          b <+ "<p>Ed25519 host fingerprint received from this destination:</p>"
          for fingerprint in check.fingerprints {
            b <+
              "<p><code class=\"ssh-key-fingerprint\">\{fingerprint}</code></p>"
          }
          if !mirror.host_keys.is_empty() &&
            check.fingerprints !=
            @repository.mirror_host_fingerprints(mirror.host_keys) {
            b <+
              "<p class=\"flash-error\" role=\"alert\">The host key has changed. Confirm with the server administrator before replacing the trusted key.</p>"
          }
          b <+
            "<p>Compare this fingerprint with the host’s published fingerprint or ask its administrator. Fetching a key does not verify the server’s identity. Confirm only if it matches. This confirmation expires after 10 minutes.</p>"
        } else if mirror.host_keys.is_empty() {
          b <+
            "<p>Initialize this destination to view its SSH host fingerprint. Sync stays disabled until you confirm that you trust the host.</p>"
        }
        b <+ "<div class=\"ssh-form-actions\">"
        if mirror.host_check is Some(check) {
          b <+
            "<form method=\"post\" action=\"\{action}/confirm-host\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{mirror.version.to_string()}\"><input type=\"hidden\" name=\"challenge\" value=\"\{check.challenge}\"><button type=\"submit\">Trust this host key</button></form>"
        }
        if !mirror.active {
          b <+
            "<form method=\"post\" action=\"\{action}/initialize-host\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{mirror.version.to_string()}\"><button type=\"submit\" class=\"secondary-button\">\{if mirror.host_check is Some(_) || !mirror.host_keys.is_empty() {"Fetch host fingerprint again"} else {"Initialize destination"}}</button></form>"
        } else {
          b <+
            "<p class=\"muted\">Disable automatic sync and save before checking a replacement host key.</p>"
        }
        b <+ "</div></section>"
      } else if mirror.id != 0L {
        b <+
          "<p class=\"settings-notice\">Save the destination address with automatic sync disabled before initializing it.</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"\{action}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{mirror.version.to_string()}\"><div class=\"field\"><label for=\"mirror-url\">Destination SSH URL</label><input id=\"mirror-url\" name=\"url\" type=\"text\" maxlength=\"2048\" value=\"\{mirror.url}\" placeholder=\"git@github.com:organization/repository.git\" required aria-describedby=\"mirror-url-help\"><p id=\"mirror-url-help\" class=\"muted\">Use user@host:path or ssh://user@host:port/path. Save address changes with automatic sync disabled, then initialize the destination to confirm its SSH host fingerprint.</p></div><fieldset><legend>Sync behavior</legend>"
      for
        (name, label, help, checked) in [
          (
            "active",
            "Enable automatic sync",
            "Queue a full sync when enabled, then sync after every push and merge.",
            mirror.active,
          ),
          (
            "force_push",
            "Allow force updates",
            "Overwrite diverged branches and moved tags on the destination. This can replace remote history.",
            mirror.force_push,
          ),
          (
            "prune",
            "Delete remote branches and tags",
            "Remove destination branches and tags that do not exist in MoonHub, including on the first sync.",
            mirror.prune,
          ),
        ] {
        b <+
          "<label class=\"checkbox-field\"><input type=\"checkbox\" name=\"\{name}\" value=\"1\""
        if checked {
          b <+ " checked"
        }
        if name == "active" && mirror.host_keys.is_empty() {
          b <+ " disabled"
        }
        b <+
          "><span><strong>\{label}</strong><span class=\"mirror-option-help muted\">\{help}</span></span></label>"
      }
      b <+
        "</fieldset><div class=\"ssh-form-actions\"><button type=\"submit\">Save mirror</button><a href=\"\{base}\">Cancel</a></div></form>"
      if mirror.id != 0L {
        b <+
          "<section class=\"mirror-history\" aria-labelledby=\"mirror-history-title\"><h2 id=\"mirror-history-title\">Sync history</h2><p class=\"muted\">Current status: \{mirror_status(mirror.status)}. Showing the 10 most recent attempts.</p>"
        if history.is_empty() {
          b <+ "<p class=\"muted\">No sync attempts yet.</p>"
        } else {
          b <+ "<ul class=\"ssh-key-list\" aria-label=\"Sync attempts\">"
          for attempt in history {
            b <+
              "<li class=\"ssh-key-item\"><div class=\"ssh-key-content\"><strong>\{mirror_status(attempt.status)}</strong><p class=\"muted\">Started \{@web_ui.timestamp(attempt.started_at)}</p>"
            if !attempt.error.is_empty() {
              b <+ "<p>\{attempt.error}</p>"
            }
            b <+ "</div></li>"
          }
          b <+ "</ul>"
        }
        b <+ "</section>"
        if !mirror.public_key.is_empty() {
          b <+
            "<details class=\"mirror-remove\"><summary>Rotate SSH key</summary><p>Generate a new key for this mirror and disable automatic sync. Add the new public key to the destination, remove the old deploy key there, then enable sync again.</p><form method=\"post\" action=\"\{action}/rotate-key\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{mirror.version.to_string()}\"><button type=\"submit\" class=\"ssh-danger-button\">Generate new SSH key</button></form></details>"
        }
        b <+
          "<details class=\"mirror-remove\"><summary>Remove mirror</summary><p>Stop syncing and remove this configuration and its history. The destination repository is kept.</p><form method=\"post\" action=\"\{action}/delete\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{mirror.version.to_string()}\"><button type=\"submit\" class=\"ssh-danger-button\">Remove mirror</button></form></details>"
      }
      b <+ "</section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "mirrors", true),
  )
}
