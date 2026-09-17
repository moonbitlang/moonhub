///|
pub fn save_mail_settings(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  form : Map[String, String],
  existing : MailSettings,
) -> Unit raise {
  guard actor.is_site_admin else {
    raise @domain.Forbidden(message="site administrator required")
  }
  let transport = form
    .get("transport")
    .unwrap_or("file")
    .trim()
    .to_lower()
    .to_owned()
  guard transport == "file" || transport == "smtp" else {
    raise @domain.BadRequest(message="transport must be file or smtp")
  }
  let host = form.get("smtp_host").unwrap_or("").trim().to_owned()
  guard host.length() <= 253 &&
    host
    .iter()
    .all(ch => {
      ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ch == '.' ||
      ch == '-' ||
      ch == ':' ||
      ch == '[' ||
      ch == ']'
    }) else {
    raise @domain.BadRequest(
      message="enter an SMTP hostname or IP address, without a scheme or path",
    )
  }
  let port_text = form.get("smtp_port").unwrap_or("587").trim().to_owned()
  let port = @string.parse_int(port_text) catch {
    _ =>
      raise @domain.BadRequest(message="SMTP port must be between 1 and 65535")
  }
  guard port >= 1 && port <= 65535 else {
    raise @domain.BadRequest(message="SMTP port must be between 1 and 65535")
  }
  let security = form
    .get("smtp_security")
    .unwrap_or("starttls")
    .trim()
    .to_lower()
    .to_owned()
  guard ["plain", "starttls", "tls"].contains(security) else {
    raise @domain.BadRequest(
      message="SMTP security must be plain, starttls, or tls",
    )
  }
  let auth = form
    .get("smtp_auth")
    .unwrap_or("plain")
    .trim()
    .to_lower()
    .to_owned()
  guard ["none", "plain", "login", "xoauth2"].contains(auth) else {
    raise @domain.BadRequest(message="SMTP authentication is invalid")
  }
  let username = form.get("smtp_username").unwrap_or("").trim().to_owned()
  let password_input = form.get("smtp_password").unwrap_or("")
  let password = if auth == "none" {
    ""
  } else if !password_input.is_empty() {
    password_input
  } else {
    existing.smtp.password
  }
  if transport == "smtp" {
    guard !host.is_empty() else {
      raise @domain.BadRequest(message="SMTP host is required")
    }
    if auth != "none" {
      guard !username.is_empty() else {
        raise @domain.BadRequest(message="SMTP username is required")
      }
      guard !password.is_empty() else {
        raise @domain.BadRequest(message="SMTP password is required")
      }
    }
  }
  let tls_trust = form
    .get("smtp_tls_trust")
    .unwrap_or("system")
    .trim()
    .to_lower()
    .to_owned()
  guard ["system", "insecure", "custom"].contains(tls_trust) else {
    raise @domain.BadRequest(
      message="TLS certificate verification setting is invalid",
    )
  }
  let tls_root_cert_file = form
    .get("smtp_tls_root_cert_file")
    .unwrap_or("")
    .trim()
    .to_owned()
  if transport == "smtp" && tls_trust == "custom" {
    guard !tls_root_cert_file.is_empty() else {
      raise @domain.BadRequest(
        message="custom TLS certificate path is required",
      )
    }
  }
  let helo_name = form
    .get("smtp_helo_name")
    .unwrap_or("localhost")
    .trim()
    .to_owned()
  let from = form
    .get("smtp_from")
    .unwrap_or(default_mail_from)
    .trim()
    .to_owned()
  guard helo_name.length() <= 253 &&
    helo_name
    .iter()
    .all(ch => {
      ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ch == '.' ||
      ch == '-' ||
      ch == ':' ||
      ch == '[' ||
      ch == ']'
    }) else {
    raise @domain.BadRequest(
      message="HELO name must be a hostname or address literal",
    )
  }
  guard username.length() <= 1024 &&
    !username.contains("\u0000") &&
    password.length() <= 4096 &&
    !password.contains("\u0000") else {
    raise @domain.BadRequest(
      message="SMTP credentials are too long or contain invalid characters",
    )
  }
  guard tls_root_cert_file.length() <= 4096 &&
    !tls_root_cert_file.contains("\u0000") &&
    from.length() <= 320 else {
    raise @domain.BadRequest(
      message="certificate path or From address is invalid",
    )
  }
  if transport == "smtp" {
    guard !helo_name.is_empty() else {
      raise @domain.BadRequest(message="HELO name is required")
    }
    guard !from.is_empty() else {
      raise @domain.BadRequest(message="From address is required")
    }
    match @core.Mailbox::address_only(from) {
      Ok(_) => ()
      Err(_) => raise @domain.BadRequest(message="From address is invalid")
    }
  }
  pool.with_client(client => {
    let _ = client.execute(
      (
        #|INSERT INTO mail_settings (
        #|  id, transport, smtp_host, smtp_port, smtp_security, smtp_auth,
        #|  smtp_username, smtp_password, smtp_tls_trust,
        #|  smtp_tls_root_cert_file, smtp_helo_name, smtp_from,
        #|  updated_by_user_id
        #|) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        #|ON CONFLICT (id) DO UPDATE SET
        #|  transport = excluded.transport,
        #|  smtp_host = excluded.smtp_host,
        #|  smtp_port = excluded.smtp_port,
        #|  smtp_security = excluded.smtp_security,
        #|  smtp_auth = excluded.smtp_auth,
        #|  smtp_username = excluded.smtp_username,
        #|  smtp_password = excluded.smtp_password,
        #|  smtp_tls_trust = excluded.smtp_tls_trust,
        #|  smtp_tls_root_cert_file = excluded.smtp_tls_root_cert_file,
        #|  smtp_helo_name = excluded.smtp_helo_name,
        #|  smtp_from = excluded.smtp_from,
        #|  updated_by_user_id = excluded.updated_by_user_id,
        #|  updated_at = datetime('now')
      ),
      params=[
        transport as &@database.DbParam,
        host as &@database.DbParam,
        port.to_int64() as &@database.DbParam,
        security as &@database.DbParam,
        auth as &@database.DbParam,
        username as &@database.DbParam,
        password as &@database.DbParam,
        tls_trust as &@database.DbParam,
        tls_root_cert_file as &@database.DbParam,
        helo_name as &@database.DbParam,
        from as &@database.DbParam,
        actor.id as &@database.DbParam,
      ],
    )
  })
}
