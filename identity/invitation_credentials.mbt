///|
pub struct InvitationCredentials {
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
pub fn invitation_credentials(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  team_id : Int64,
  invitation_id : Int64,
) -> InvitationCredentials raise {
  guard actor.is_site_admin else {
    raise @domain.Forbidden(message="site administrator required")
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
      raise @domain.NotFound(message="active invitation email not found")
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
