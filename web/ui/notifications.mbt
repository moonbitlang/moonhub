///|
// One subscription control shared by Issues and MRs, including the explicit
// request exception so users know exactly what muting a discussion does.
pub fn render_thread_subscription(
  subscription : @collaboration.ThreadSubscription,
  csrf : String,
) -> @moonback.Html {
  Html(b => {
    b <+
      "<form class=\"thread-subscription\" method=\"post\" action=\"/-/notifications/threads/\{subscription.id.to_string()}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"subscribed\" value=\"\{if subscription.subscribed { "0" } else { "1" }}\"><button class=\"secondary-button\" type=\"submit\">\{if subscription.subscribed { "Unsubscribe from updates" } else { "Subscribe to updates" }}</button><span class=\"muted\">Direct review requests and assignments still notify you.</span></form>"
  })
}
