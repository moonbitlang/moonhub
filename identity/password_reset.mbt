///|
pub fn request_password_reset(
  pool : @database.Database,
  email : String,
) -> Unit raise {
  let email = @domain.normalize_email(email)
  guard @domain.valid_email(email) && email.length() <= 254 else { return }
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        guard tx.query_opt(
            "SELECT id FROM \"user\" WHERE email = ? AND status = 'active'",
            params=[email],
          )
          is Some(user) else {
          return
        }
        let user_id : Int64 = user.get_name("id")
        // Keep throttling history even after a code is consumed. Requesting a new
        // code does not invalidate an earlier one that is still in transit.
        let recent = tx.query_one(
          (
            #|SELECT count(*) AS count,
            #|  COALESCE(MAX(created_at) > datetime('now', '-1 minute'), 0) AS cooling_down
            #|FROM password_reset
            #|WHERE user_id = ? AND created_at > datetime('now', '-1 hour')
          ),
          params=[user_id],
        )
        guard !(recent.get_name("cooling_down") : Bool) &&
          (recent.get_name("count") : Int64) < 5L else {
          return
        }
        let code = random_hex(16)
        let reset = tx.query_one(
          (
            #|INSERT INTO password_reset (user_id, email, token_hash)
            #|VALUES (?, ?, ?) RETURNING id
          ),
          params=[user_id, email, hash_token(code)],
        )
        let reset_id : Int64 = reset.get_name("id")
        let body =
          $|A password reset was requested for your Moonhub account.
          $|
          $|Reset code: \{code}
          $|
          $|On your Moonhub site, choose Forgot password, then I have a reset code.
          $|Enter your email, this code, and a new password. The code expires in 30 minutes.
          $|If you did not request this, ignore this email. Your password has not changed.
        let _ = tx.execute(
          (
            #|INSERT INTO email_outbox (password_reset_id, to_email, subject, body, template)
            #|VALUES (?, ?, 'Reset your Moonhub password', ?, 'password_reset')
          ),
          params=[reset_id, email, body],
        )
      },
      immediate=true,
    )
  })
}

///|
pub fn new_password_error(password : String) -> String? {
  if password.length() < 8 {
    Some("New password must be at least 8 characters.")
  } else if @utf8.encode(password).length() > 72 {
    Some("New password must be at most 72 bytes.")
  } else {
    None
  }
}

///|
pub fn reset_password(
  pool : @database.Database,
  email : String,
  code : String,
  password : String,
) -> Bool raise {
  if new_password_error(password) is Some(message) {
    raise @domain.BadRequest(message~)
  }
  let email = @domain.normalize_email(email)
  let code = code.trim().to_owned().to_lower()
  guard code.length() == 32 &&
    code.iter().all(ch => (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')) else {
    return false
  }
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        guard tx.query_opt(
            (
              #|SELECT r.user_id FROM password_reset AS r
              #|JOIN "user" AS u ON u.id = r.user_id
              #|WHERE r.token_hash = ? AND r.email = ? AND u.email = r.email
              #|  AND u.status = 'active' AND r.used_at IS NULL
              #|  AND r.expires_at > datetime('now')
            ),
            params=[hash_token(code), email],
          )
          is Some(reset) else {
          return false
        }
        let user_id : Int64 = reset.get_name("user_id")
        let _ = tx.execute(
          "UPDATE \"user\" SET password_hash = ?, updated_at = datetime('now') WHERE id = ?",
          params=[hash_password(password), user_id],
        )
        let _ = tx.execute(
          "UPDATE session SET revoked_at = datetime('now') WHERE user_id = ? AND revoked_at IS NULL",
          params=[user_id],
        )
        let _ = tx.execute(
          "UPDATE access_token SET revoked_at = datetime('now') WHERE user_id = ? AND revoked_at IS NULL",
          params=[user_id],
        )
        let _ = tx.execute(
          "UPDATE password_reset SET used_at = datetime('now') WHERE user_id = ? AND used_at IS NULL",
          params=[user_id],
        )
        let _ = tx.execute(
          (
            #|UPDATE email_outbox SET body = 'Password reset code is no longer valid.',
            #|  status = CASE WHEN status = 'pending' THEN 'failed' ELSE status END,
            #|  locked_at = NULL, locked_by = NULL
            #|WHERE template = 'password_reset' AND password_reset_id IN (
            #|  SELECT id FROM password_reset WHERE user_id = ?
            #|)
          ),
          params=[user_id],
        )
        let _ = tx.execute(
          (
            #|INSERT INTO email_outbox (to_email, subject, body, template)
            #|VALUES (?, 'Your Moonhub password was changed',
            #|  'Your Moonhub password was reset, all previous sessions were signed out and all access tokens were revoked. If this was not you, contact your site administrator immediately.',
            #|  'password_changed')
          ),
          params=[email],
        )
        true
      },
      immediate=true,
    )
  })
}
