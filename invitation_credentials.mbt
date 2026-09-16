///|
struct InvitationCredentials {
  email : String
  name_key : String
  expires_at : String
  subject : String
  body : String
  email_status : String
  email_sent_at : String?
  email_last_error : String?
}

///|
fn invitation_credentials(
  pool : Database,
  actor : CurrentUser,
  team_id : Int64,
  invitation_id : Int64,
) -> InvitationCredentials raise {
  guard actor.is_site_admin else {
    raise Forbidden(message="site administrator required")
  }
  pool.with_client(client => {
    guard client.query_opt(
        (
          #|SELECT i.email, i.name_key, i.expires_at, e.subject, e.body,
          #|  e.status AS email_status, e.sent_at AS email_sent_at,
          #|  e.last_error AS email_last_error
          #|FROM invitation AS i JOIN email_outbox AS e ON e.invitation_id = i.id
          #|WHERE i.id = ? AND i.team_id = ? AND i.kind = 'team_member'
          #|  AND i.status = 'sent' AND i.expires_at > datetime('now')
          #|  AND e.template = 'team_invitation'
          #|ORDER BY e.id DESC LIMIT 1
        ),
        params=[invitation_id, team_id],
      )
      is Some(row) else {
      raise NotFound(message="active invitation email not found")
    }
    {
      email: row.get_name("email"),
      name_key: row.get_name("name_key"),
      expires_at: row.get_name("expires_at"),
      subject: row.get_name("subject"),
      body: row.get_name("body"),
      email_status: row.get_name("email_status"),
      email_sent_at: row.get_name("email_sent_at"),
      email_last_error: row.get_name("email_last_error"),
    }
  })
}

///|
fn render_invitation_credentials(
  assets : Map[String, String],
  user : CurrentUser,
  team : TeamSummary,
  details : InvitationCredentials,
) -> @moonback.Html {
  layout(
    "Invitation sign-in details",
    assets,
    Html(b => {
      b <+
        "<nav class=\"ssh-settings-back\" aria-label=\"Team\"><a href=\"/teams/\{team.name_key}\">\{team.display_name}</a></nav><section class=\"page-heading\"><h1>Invitation sign-in details</h1></section><div class=\"content-stack invitation-details\"><section><dl class=\"ssh-address-details\"><div><dt>Username</dt><dd class=\"path\">\{details.name_key}</dd></div><div><dt>Email</dt><dd>\{details.email}</dd></div><div><dt>Expires</dt><dd>\{details.expires_at} UTC</dd></div><div><dt>Delivery</dt><dd>\{details.email_status}</dd></div>"
      if details.email_sent_at is Some(sent_at) {
        b <+ "<div><dt>Sent</dt><dd>\{sent_at} UTC</dd></div>"
      }
      b <+ "</dl>"
      if details.email_last_error is Some(_) {
        b <+ "<p class=\"flash-error\">\{email_delivery_error_message}</p>"
      }
      b <+
        "</section><section><h2 class=\"section-title\">Invitation email</h2><p>\{details.subject}</p><pre class=\"invitation-email\">\{details.body}</pre></section></div>"
    }),
    current_user=Some(user),
  )
}
