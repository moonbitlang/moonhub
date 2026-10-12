///|
fn render_inbox(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  filter : String,
  page : Int64,
  items : Array[@collaboration.InboxItem],
  unread : Int64,
  email_enabled : Bool,
  csrf : String,
  saved : Bool,
) -> @moonback.Html {
  @web_ui.layout(
    "Inbox",
    assets,
    Html(b => {
      b <+
        "<div class=\"page-heading\"><div><h1>Inbox</h1><p class=\"page-subtitle\">Your reviews, assigned issues and discussion updates.</p></div>"
      let through = items.fold(init=0L, (max, item) => {
        if item.id > max {
          item.id
        } else {
          max
        }
      })
      if unread > 0L && through > 0L && page == 1L {
        b <+
          "<form method=\"post\" action=\"/-/notifications/read-all\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"through\" value=\"\{through.to_string()}\"><button class=\"secondary-button\" type=\"submit\">Mark all read</button></form>"
      }
      b <+
        "</div><nav class=\"mr-tabs inbox-tabs\" aria-label=\"Inbox filter\">"
      for
        (key, label) in [
          ("unread", "Unread (\{unread})"),
          ("reviews", "Review requests"),
          ("assigned", "Assigned issues"),
          ("all", "All notifications"),
        ] {
        b <+ "<a href=\"/-/notifications?filter=\{key}\""
        if filter == key {
          b <+ " aria-current=\"page\""
        }
        b <+ ">\{label}</a>"
      }
      b <+ "</nav><ul class=\"inbox-list\">"
      for i, item in items {
        if i < 50 {
          b <+
            "<li class=\"inbox-item\"><div class=\"inbox-item-content\"><p class=\"inbox-event\">\{@collaboration.notification_label(item.kind)}"
          if !item.read {
            b <+ "<span class=\"inbox-unread\">Unread</span>"
          }
          b <+
            "</p><a class=\"inbox-title\" href=\"\{item.url()}\">\{item.title}</a><p class=\"muted\">\{item.repo.path()} · \{if item.issue { "#" } else { "!" }}\{item.number.to_string()}"
          if !item.actor.is_empty() {
            b <+ " · \{item.actor}"
          }
          if item.version > 0L {
            b <+ " · v\{item.version.to_string()}"
          }
          b <+
            " · <time>\{item.created_at}</time></p></div><div class=\"inbox-item-actions\">"
          if item.id > 0L && !item.read {
            b <+
              "<form method=\"post\" action=\"/-/notifications/\{item.id.to_string()}/read\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button class=\"secondary-button\" type=\"submit\">Read and open</button></form>"
          }
          b <+ "</div></li>"
        }
      }
      if items.is_empty() {
        let (title, hint) = match filter {
          "reviews" =>
            (
              "No reviews waiting for you", "Review requests appear here when a ready merge request needs your review.",
            )
          "assigned" =>
            (
              "No open issues assigned to you", "Issues assigned to you appear here until they are closed or reassigned.",
            )
          "all" =>
            (
              "No notifications yet", "Updates appear when someone requests your review, assigns an issue or replies to a discussion you follow.",
            )
          _ =>
            (
              "You're caught up", "No unread updates. You can still check your review requests and assigned issues.",
            )
        }
        b <+
          "<li class=\"inbox-empty\"><h2>\{title}</h2><p class=\"muted\">\{hint}</p></li>"
      }
      b <+ "</ul><nav class=\"mr-actions\" aria-label=\"Inbox pagination\">"
      if page > 1L {
        b <+
          "<a href=\"/-/notifications?filter=\{filter}&amp;page=\{(page - 1L).to_string()}\">Newer items</a>"
      }
      if items.length() > 50 {
        b <+
          "<a href=\"/-/notifications?filter=\{filter}&amp;page=\{(page + 1L).to_string()}\">Older items</a>"
      }
      b <+
        "</nav><section class=\"inbox-settings\" aria-label=\"Notification settings\"><h2>Email notifications</h2><p class=\"muted\">Send new collaboration updates to your account email using the site's email delivery settings.</p>"
      if saved {
        b <+
          "<p class=\"settings-notice\" role=\"status\">Notification settings saved.</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"/-/notifications/settings\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><label class=\"mr-checkbox\"><input type=\"checkbox\" name=\"email\""
      if email_enabled {
        b <+ " checked"
      }
      b <+
        "><span>Email me about collaboration updates</span></label><div><button type=\"submit\">Save notification settings</button></div></form></section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.WorkspaceNavigation("notifications"),
  )
}
