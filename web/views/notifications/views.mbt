///|
fn render_inbox(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  filter : String,
  page : Int64,
  groups : Array[@collaboration.InboxGroup],
  unread : Int64,
  email_enabled : Bool,
  csrf : String,
  saved : Bool,
  settings : Bool,
) -> @moonback.Html {
  @web_ui.layout(
    "Inbox",
    assets,
    Html(b => {
      b <+
        "<div class=\"page-heading\"><div><h1>Inbox</h1><p class=\"page-subtitle\">Your reviews, assigned issues and discussion updates.</p></div>"
      let through = groups.fold(init=0L, (max, group) => {
        let item = group.item
        if item.id > max {
          item.id
        } else {
          max
        }
      })
      if !settings && unread > 0L && through > 0L && page == 1L {
        b <+
          "<form method=\"post\" action=\"/-/notifications/read-all\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"through\" value=\"\{through.to_string()}\"><button class=\"secondary-button\" type=\"submit\">Mark all read</button></form>"
      }
      b <+
        "<a class=\"secondary-link\" href=\"/-/notifications?settings=1\">Notification settings</a></div>"
      if !settings {
        b <+ "<nav class=\"page-tabs inbox-tabs\" aria-label=\"Inbox filter\">"
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
        for i, group in groups {
          if i >= 50 {
            break
          }
          let item = group.item
          let through = group.events.fold(init=0L, (max, event) => {
            Int64::max(max, event.id)
          })
          b <+
            "<li class=\"inbox-item\"><div class=\"inbox-item-content\"><div class=\"record-title\"><span class=\"mr-state\" data-state=\"\{group.status}\">\{group.status}</span><a class=\"inbox-title\" href=\"\{group.url()}\">\{item.title}</a></div><p class=\"record-meta\">\{item.repo.path()} · \{if item.issue { "#" } else { "!" }}\{item.number.to_string()}"
          if group.unread > 0L {
            b <+
              "<span class=\"inbox-unread\">\{group.unread.to_string()} unread updates</span>"
          }
          b <+ "</p>"
          if filter == "reviews" || filter == "assigned" {
            b <+
              "<p class=\"inbox-event\">\{@collaboration.notification_label(item.kind)}</p>"
          } else if group.status == "merged" || group.status == "closed" {
            b <+
              "<p class=\"muted\">Historical updates · this \{if item.issue { "issue" } else { "merge request" }} is \{group.status}.</p>"
          }
          if !group.events.is_empty() {
            b <+
              "<details class=\"inbox-history\"><summary>Recent activity</summary><ol>"
            for event in group.events {
              b <+
                "<li><a href=\"\{event.url()}\">\{@collaboration.notification_label(event.kind)}</a><span class=\"muted\"> · \{event.actor}"
              if event.version > 0L {
                b <+ " · v\{event.version.to_string()}"
              }
              b <+
                " · \{@web_ui.timestamp(event.created_at, relative=true)}</span></li>"
            }
            b <+
              "</ol><p class=\"muted\">Showing up to 10 recent events. Open the discussion for its full history.</p></details>"
          }
          b <+ "</div><div class=\"inbox-item-actions\">"
          if group.unread > 0L && through > 0L {
            b <+
              "<form method=\"post\" action=\"/-/notifications/threads/\{item.thread_id.to_string()}/read\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"through\" value=\"\{through.to_string()}\"><input type=\"hidden\" name=\"filter\" value=\"\{filter}\"><input type=\"hidden\" name=\"page\" value=\"\{page.to_string()}\"><button class=\"secondary-button\" type=\"submit\">Mark read</button></form>"
          }
          b <+ "</div></li>"
        }
        if groups.is_empty() {
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
        if groups.length() > 50 {
          b <+
            "<a href=\"/-/notifications?filter=\{filter}&amp;page=\{(page + 1L).to_string()}\">Older items</a>"
        }
        b <+ "</nav>"
      } else {
        b <+
          "<a class=\"back-link\" href=\"/-/notifications\">Back to inbox</a><section class=\"inbox-settings\" aria-label=\"Notification settings\"><h2>Email notifications</h2><p class=\"muted\">Send new collaboration updates to your account email using the site's email delivery settings.</p>"
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
      }
    }),
    current_user=Some(actor),
    navigation=@web_ui.WorkspaceNavigation("notifications"),
  )
}
