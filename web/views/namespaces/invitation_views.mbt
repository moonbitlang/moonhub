///|
fn render_invitation_credentials(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  team : @identity.TeamSummary,
  details : @identity.InvitationCredentials,
) -> @moonback.Html {
  @web_ui.layout(
    "Invitation sign-in details",
    assets,
    Html(b => {
      b <+
        "<nav class=\"ssh-settings-back\" aria-label=\"Team\"><a href=\"/\{team.name_key}\">\{team.display_name}</a></nav><section class=\"page-heading\"><h1>Invitation sign-in details</h1></section><div class=\"content-stack invitation-details\"><section><dl class=\"ssh-address-details\"><div><dt>Username</dt><dd class=\"path\">\{details.name_key}</dd></div><div><dt>Email</dt><dd>\{details.email}</dd></div><div><dt>Expires</dt><dd>\{details.expires_at} UTC</dd></div><div><dt>Delivery</dt><dd>\{details.email_status}</dd></div>"
      if details.email_sent_at is Some(sent_at) {
        b <+ "<div><dt>Sent</dt><dd>\{sent_at} UTC</dd></div>"
      }
      b <+ "</dl>"
      if details.email_last_error is Some(_) {
        b <+
          "<p class=\"flash-error\">\{@domain.email_delivery_error_message}</p>"
      }
      b <+
        "</section><section><h2 class=\"section-title\">Invitation email</h2><p>\{details.subject}</p><pre class=\"invitation-email\">\{details.body}</pre></section></div>"
    }),
    current_user=Some(user),
    navigation=@web_ui.TeamNavigation(team, "invitations"),
  )
}
