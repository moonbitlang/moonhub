///|
fn render_webhooks(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  hooks : Array[@webhooks.Hook],
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(repo)}/settings/webhooks"
  @web_ui.layout(
    "Webhooks",
    assets,
    Html(b => {
      b <+
        "<section class=\"webhook-settings ssh-settings\"><div class=\"page-heading page-heading--actions\"><div><h1>Webhooks</h1><p class=\"muted\">Send repository events to your integrations.</p></div><a class=\"button-link\" href=\"\{base}/new\">Add webhook</a></div>"
      if hooks.is_empty() {
        b <+
          "<p class=\"ssh-keys-empty muted\">No webhooks yet. Add an endpoint to receive signed JSON events.</p>"
      } else {
        b <+ "<ul class=\"ssh-key-list\" aria-label=\"Repository webhooks\">"
        for hook in hooks {
          b <+
            "<li class=\"ssh-key-item\"><div class=\"ssh-key-content\"><div class=\"ssh-key-heading\"><h2><a href=\"\{base}/\{hook.id.to_string()}\">\{hook.url}</a></h2><span class=\"ssh-key-state\">\{if hook.active {"Active"} else {"Disabled"}}</span></div><p class=\"muted\">\{hook.events.replace(old=",",new=", ")}</p><div class=\"ssh-form-actions\"><a href=\"\{base}/\{hook.id.to_string()}\">Edit</a><a href=\"\{base}/\{hook.id.to_string()}/deliveries\">Deliveries</a></div></div></li>"
        }
        b <+ "</ul>"
      }
      b <+
        "<p class=\"muted\">Delivery is at least once. Receivers should deduplicate X-MoonHub-Delivery. Events use MoonHub payload schema v1.</p></section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "webhooks", true),
  )
}

///|
fn render_webhook_form(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  hook : @webhooks.Hook,
  csrf : String,
  error : String?,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(repo)}/settings/webhooks"
  let title = if hook.id == 0L { "Add webhook" } else { "Edit webhook" }
  @web_ui.layout(
    title,
    assets,
    Html(b => {
      b <+
        "<section class=\"webhook-settings ssh-settings ssh-settings--form\"><nav class=\"ssh-settings-back\" aria-label=\"Settings\"><a href=\"\{base}\">Webhooks</a></nav><h1>\{title}</h1>"
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"\{base}\{if hook.id==0L {""} else {"/\{hook.id.to_string()}"}}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{hook.version.to_string()}\"><div class=\"field\"><label for=\"webhook-url\">Payload URL</label><input id=\"webhook-url\" name=\"url\" type=\"url\" maxlength=\"2048\" value=\"\{hook.url}\" placeholder=\"https://example.com/hooks/moonhub\" required aria-describedby=\"webhook-url-help\"><p id=\"webhook-url-help\" class=\"muted\">HTTPS required. Private destinations and HTTP require an administrator-allowed origin. Redirects are never followed.</p></div><div class=\"field\"><label for=\"webhook-secret\">Signing secret</label><input id=\"webhook-secret\" name=\"secret\" type=\"password\" autocomplete=\"new-password\" minlength=\"16\" maxlength=\"256\""
      if hook.id == 0L {
        b <+ " required"
      }
      b <+
        "><p class=\"muted\">Use 16–256 characters without spaces.\{if hook.id==0L {""} else {" Leave blank to keep the current secret."}} Verify X-MoonHub-Signature-256 against the exact request body.</p></div><fieldset><legend>Events</legend>"
      for kind in @webhooks.event_kinds {
        b <+
          "<label class=\"checkbox-field\"><input type=\"checkbox\" name=\"event_\{kind}\" value=\"1\""
        if hook.events.split(",").any(value => value == kind) {
          b <+ " checked"
        }
        b <+ "><span>\{kind}</span></label>"
      }
      b <+
        "</fieldset><label class=\"checkbox-field\"><input type=\"checkbox\" name=\"active\" value=\"1\""
      if hook.active {
        b <+ " checked"
      }
      b <+
        "><span>Active</span></label><p class=\"muted\">Saving changes cancels queued deliveries. A request already in flight may still arrive.</p><div class=\"ssh-form-actions\"><button type=\"submit\">Save webhook</button><a href=\"\{base}\">Cancel</a></div></form>"
      if hook.id != 0L {
        b <+
          "<div class=\"ssh-form-actions\"><a href=\"\{base}/\{hook.id.to_string()}/deliveries\">View deliveries</a><form method=\"post\" action=\"\{base}/\{hook.id.to_string()}/ping\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button type=\"submit\">Send test event</button></form></div><details><summary>Delete webhook</summary><p>Remove this webhook and its delivery history. This cannot be undone.</p><form method=\"post\" action=\"\{base}/\{hook.id.to_string()}/delete\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{hook.version.to_string()}\"><button type=\"submit\" class=\"ssh-danger-button\">Delete webhook</button></form></details>"
      }
      b <+ "</section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "webhooks", true),
  )
}

///|
fn render_webhook_deliveries(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  hook : @webhooks.Hook,
  rows : Array[@webhooks.Delivery],
  page : Int64,
  csrf : String,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(repo)}/settings/webhooks/\{hook.id.to_string()}"
  @web_ui.layout(
    "Webhook deliveries",
    assets,
    Html(b => {
      b <+
        "<section class=\"webhook-settings ssh-settings\"><a href=\"\{base}\">Edit webhook</a><div class=\"page-heading page-heading--actions\"><div><h1>Deliveries</h1><p class=\"path\">\{hook.url}</p></div><form method=\"post\" action=\"\{base}/ping\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button type=\"submit\">Send test event</button></form></div><p class=\"muted\">Failed requests receive up to five attempts. Reload to see current results.</p>"
      if rows.is_empty() {
        b <+ "<p class=\"ssh-keys-empty muted\">No deliveries on this page.</p>"
      } else {
        b <+ "<ul class=\"ssh-key-list\" aria-label=\"Webhook deliveries\">"
        for d in rows {
          b <+
            "<li class=\"ssh-key-item\"><div class=\"ssh-key-content\"><div class=\"ssh-key-heading\"><h2><a href=\"\{base}/deliveries/\{d.id.to_string()}\">#\{d.id.to_string()} · \{d.kind}</a></h2><span class=\"ssh-key-state\">\{d.status}</span></div><p class=\"muted\">\{@web_ui.timestamp(d.created_at)} · \{d.attempts.to_string()} attempts · HTTP \{d.response_code.to_string()}</p>"
          if !d.error.is_empty() {
            b <+ "<p>\{d.error}</p>"
          }
          if d.status == "pending" {
            b <+
              "<p class=\"muted\">Next attempt: \{@web_ui.timestamp(d.next_attempt_at)}</p>"
          }
          if hook.active &&
            ["failed", "succeeded", "cancelled"].contains(d.status) {
            b <+
              "<form method=\"post\" action=\"\{base}/redeliver\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"delivery\" value=\"\{d.id.to_string()}\"><button type=\"submit\">Redeliver #\{d.id.to_string()}</button></form>"
          }
          b <+ "</div></li>"
        }
        b <+ "</ul>"
      }
      b <+ "<nav class=\"ssh-form-actions\" aria-label=\"Delivery pages\">"
      if page > 1L {
        b <+
          "<a href=\"\{base}/deliveries?page=\{(page-1L).to_string()}\">Newer deliveries</a>"
      }
      if rows.length() == 50 {
        b <+
          "<a href=\"\{base}/deliveries?page=\{(page+1L).to_string()}\">Older deliveries</a>"
      }
      b <+ "</nav></section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "webhooks", true),
  )
}
