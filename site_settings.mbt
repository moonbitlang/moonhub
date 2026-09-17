///|
fn site_settings_module(assets : Map[String, String]) -> @moonback.Module {
  Module(ctx => {
    let pool = db_pool(ctx)
    let addresses = ctx
      .config()
      .get_custom(config_ssh_addresses)
      .unwrap_or(no_ssh_address_config)
    ctx.get("/-/admin/settings/ssh", async fn(req, res) {
      let actor = require_current_user(req)
      guard actor.is_site_admin else {
        raise Forbidden(message="site administrator required")
      }
      let endpoint = effective_ssh_endpoint(pool, addresses)
      let mail = load_mail_settings(pool)
      res.send_html(
        render_ssh_settings(
          assets,
          actor,
          request_form_token(req, "site-ssh-settings"),
          request_form_token(req, "site-mail-settings"),
          addresses,
          endpoint.map(value => value.host).unwrap_or(""),
          endpoint.map(value => value.port.to_string()).unwrap_or("22"),
          None,
          req.query().get("saved") == Some("1"),
          mail,
          None,
          req.query().get("saved_mail") == Some("1"),
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/-/admin/settings/ssh", async fn(req, res) {
      let actor = require_current_user(req)
      guard actor.is_site_admin else {
        raise Forbidden(message="site administrator required")
      }
      let form = protected_form(req, "site-ssh-settings")
      let host = form.get("host").unwrap_or("")
      let port = form.get("port").unwrap_or("")
      save_ssh_endpoint(pool, actor, addresses, host, port) catch {
        BadRequest(message~) => {
          res.send_html(
            render_ssh_settings(
              assets,
              actor,
              request_form_token(req, "site-ssh-settings"),
              request_form_token(req, "site-mail-settings"),
              addresses,
              host,
              port,
              Some(message),
              false,
              load_mail_settings(pool),
              None,
              false,
            ),
            status=400,
            headers=private_page_headers(),
          )
          return
        }
        err => raise err
      }
      res.send_void(
        status=303,
        headers=private_page_headers(location="/-/admin/settings/ssh?saved=1"),
      )
    })
    ctx.post("/-/admin/settings/mail", async fn(req, res) {
      let actor = require_current_user(req)
      guard actor.is_site_admin else {
        raise Forbidden(message="site administrator required")
      }
      let form = protected_form(req, "site-mail-settings")
      let existing = load_mail_settings(pool)
      save_mail_settings(pool, actor, form, existing) catch {
        BadRequest(message~) => {
          let endpoint = effective_ssh_endpoint(pool, addresses)
          res.send_html(
            render_ssh_settings(
              assets,
              actor,
              request_form_token(req, "site-ssh-settings"),
              request_form_token(req, "site-mail-settings"),
              addresses,
              endpoint.map(value => value.host).unwrap_or(""),
              endpoint.map(value => value.port.to_string()).unwrap_or("22"),
              None,
              false,
              existing,
              Some(message),
              false,
              mail_form=form,
            ),
            status=400,
            headers=private_page_headers(),
          )
          return
        }
        err => raise err
      }
      res.send_void(
        status=303,
        headers=private_page_headers(
          location="/-/admin/settings/ssh?saved_mail=1",
        ),
      )
    })
  })
}

///|
fn render_ssh_settings(
  assets : Map[String, String],
  user : CurrentUser,
  csrf : String,
  mail_csrf : String,
  config : SshAddressConfig,
  host : String,
  port : String,
  error : String?,
  saved : Bool,
  mail : MailSettings,
  mail_error : String?,
  mail_saved : Bool,
  mail_form? : Map[String, String],
) -> @moonback.Html {
  let preview = SshEndpoint::from_fields(host, port).clone_url({
    owner: "team",
    name: "repository",
  }) catch {
    _ => "Not configured"
  }
  let locked = config.public_override is Some(_)
  let mail_values : Map[String, String] = {
    "transport": mail.transport,
    "smtp_host": mail.smtp.host,
    "smtp_port": mail.smtp.port.to_string(),
    "smtp_security": mail.smtp.security,
    "smtp_auth": mail.smtp.auth,
    "smtp_username": mail.smtp.username,
    "smtp_tls_trust": mail.smtp.tls_trust,
    "smtp_tls_root_cert_file": mail.smtp.tls_root_cert_file,
    "smtp_helo_name": mail.smtp.helo_name,
    "smtp_from": mail.smtp.from,
  }
  if mail_form is Some(form) {
    for key in mail_values.keys().to_array() {
      if form.get(key) is Some(value) {
        mail_values[key] = value
      }
    }
  }
  layout(
    "Site settings",
    assets,
    Html(b => {
      b <+
        "<div class=\"page-heading\"><h1>Site settings</h1></div><section id=\"ssh-access\" class=\"ssh-address-settings\"><h2>SSH access</h2>"
      if locked {
        b <+
          "<p class=\"settings-notice\" role=\"status\">Managed by deployment configuration</p>"
      }
      if saved {
        b <+
          "<p class=\"settings-success\" role=\"status\">SSH settings saved.</p>"
      }
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<form class=\"form-stack\" data-ssh-address-form method=\"post\" action=\"/-/admin/settings/ssh\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><fieldset class=\"ssh-address-fields\""
      if locked {
        b <+ " disabled"
      }
      b <+
        "><legend>Public SSH address</legend><div class=\"field\"><label for=\"ssh-public-host\"><span>Hostname or IP address</span></label><input id=\"ssh-public-host\" name=\"host\" value=\"\{host}\" maxlength=\"253\" autocomplete=\"off\" spellcheck=\"false\" required></div><div class=\"field\"><label for=\"ssh-public-port\"><span>Port</span></label><input id=\"ssh-public-port\" name=\"port\" type=\"number\" min=\"1\" max=\"65535\" value=\"\{port}\" required></div></fieldset><dl class=\"ssh-address-details\"><div><dt>SSH username</dt><dd><code>git</code></dd></div><div><dt>Example clone URL</dt><dd><output class=\"path\" data-ssh-address-preview aria-live=\"polite\">\{preview}</output></dd></div></dl><button type=\"submit\""
      if locked {
        b <+ " disabled"
      }
      b <+
        ">Save settings</button></form><section class=\"ssh-internal-address\"><h2>Deployment connection</h2><dl class=\"ssh-address-details\"><div><dt>Internal SSH endpoint</dt><dd class=\"path\">"
      match config.internal {
        Some(endpoint) => b <+ "ssh://git@\{endpoint.authority()}"
        None => b <+ "Not configured"
      }
      b <+ "</dd></div></dl></section></section>"
      b <+
        "<section id=\"email-delivery\" class=\"mail-settings\"><h2>Email delivery</h2>"
      if mail_saved {
        b <+
          "<p class=\"settings-success\" role=\"status\">Email settings saved.</p>"
      }
      if mail_error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"/-/admin/settings/mail\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{mail_csrf}\"><fieldset class=\"mail-fields\"><legend>SMTP delivery</legend><div class=\"field\"><label for=\"mail-transport\"><span>Transport</span></label><select id=\"mail-transport\" name=\"transport\"><option value=\"file\""
      if mail_values["transport"] == "file" {
        b <+ " selected"
      }
      b <+ ">File outbox</option><option value=\"smtp\""
      if mail_values["transport"] == "smtp" {
        b <+ " selected"
      }
      b <+
        ">SMTP</option></select></div><div class=\"field\"><label for=\"smtp-host\"><span>SMTP host</span></label><input id=\"smtp-host\" name=\"smtp_host\" value=\"\{mail_values["smtp_host"]}\" maxlength=\"253\" autocomplete=\"off\" spellcheck=\"false\"></div><div class=\"field\"><label for=\"smtp-port\"><span>SMTP port</span></label><input id=\"smtp-port\" name=\"smtp_port\" type=\"number\" min=\"1\" max=\"65535\" value=\"\{mail_values["smtp_port"]}\" required></div><div class=\"field\"><label for=\"smtp-security\"><span>Security</span></label><select id=\"smtp-security\" name=\"smtp_security\"><option value=\"plain\""
      if mail_values["smtp_security"] == "plain" {
        b <+ " selected"
      }
      b <+ ">Plain</option><option value=\"starttls\""
      if mail_values["smtp_security"] == "starttls" {
        b <+ " selected"
      }
      b <+ ">STARTTLS</option><option value=\"tls\""
      if mail_values["smtp_security"] == "tls" {
        b <+ " selected"
      }
      b <+
        ">TLS</option></select></div><div class=\"field\"><label for=\"smtp-auth\"><span>Authentication</span></label><select id=\"smtp-auth\" name=\"smtp_auth\"><option value=\"none\""
      if mail_values["smtp_auth"] == "none" {
        b <+ " selected"
      }
      b <+ ">None</option><option value=\"plain\""
      if mail_values["smtp_auth"] == "plain" {
        b <+ " selected"
      }
      b <+ ">PLAIN</option><option value=\"login\""
      if mail_values["smtp_auth"] == "login" {
        b <+ " selected"
      }
      b <+ ">LOGIN</option><option value=\"xoauth2\""
      if mail_values["smtp_auth"] == "xoauth2" {
        b <+ " selected"
      }
      b <+
        ">XOAUTH2</option></select></div><div class=\"field\"><label for=\"smtp-username\"><span>Username</span></label><input id=\"smtp-username\" name=\"smtp_username\" value=\"\{mail_values["smtp_username"]}\" maxlength=\"1024\" autocomplete=\"off\"></div><div class=\"field\"><label for=\"smtp-password\"><span>Password (unchanged when blank)</span></label><input id=\"smtp-password\" name=\"smtp_password\" type=\"password\" value=\"\" maxlength=\"4096\" autocomplete=\"new-password\"></div>"
      if !mail.smtp.password.is_empty() {
        b <+ "<p class=\"muted\">Password is configured.</p>"
      }
      b <+
        "<div class=\"field\"><label for=\"smtp-from\"><span>From address</span></label><input id=\"smtp-from\" name=\"smtp_from\" type=\"email\" value=\"\{mail_values["smtp_from"]}\" maxlength=\"320\" autocomplete=\"off\"></div></fieldset><details class=\"mail-advanced\""
      if mail_error is Some(_) {
        b <+ " open"
      }
      b <+
        "><summary>Advanced SMTP settings</summary><div class=\"form-stack\"><div class=\"field\"><label for=\"smtp-tls-trust\"><span>TLS certificate verification</span></label><select id=\"smtp-tls-trust\" name=\"smtp_tls_trust\"><option value=\"system\""
      if mail_values["smtp_tls_trust"] == "system" {
        b <+ " selected"
      }
      b <+ ">System certificates</option><option value=\"insecure\""
      if mail_values["smtp_tls_trust"] == "insecure" {
        b <+ " selected"
      }
      b <+ ">Disable verification</option><option value=\"custom\""
      if mail_values["smtp_tls_trust"] == "custom" {
        b <+ " selected"
      }
      b <+
        ">Custom PEM file</option></select></div><div class=\"field\"><label for=\"smtp-tls-root-cert-file\"><span>Custom PEM file path</span></label><input id=\"smtp-tls-root-cert-file\" name=\"smtp_tls_root_cert_file\" value=\"\{mail_values["smtp_tls_root_cert_file"]}\" maxlength=\"4096\" autocomplete=\"off\"></div><div class=\"field\"><label for=\"smtp-helo-name\"><span>HELO name</span></label><input id=\"smtp-helo-name\" name=\"smtp_helo_name\" value=\"\{mail_values["smtp_helo_name"]}\" maxlength=\"253\" autocomplete=\"off\"></div></div></details><button type=\"submit\">Save email settings</button></form></section>"
    }),
    head_end=repository_assets_head(assets),
    current_user=Some(user),
    navigation=SiteNavigation,
  )
}

///|
fn save_mail_settings(
  pool : Database,
  actor : CurrentUser,
  form : Map[String, String],
  existing : MailSettings,
) -> Unit raise {
  guard actor.is_site_admin else {
    raise Forbidden(message="site administrator required")
  }
  let transport = form
    .get("transport")
    .unwrap_or("file")
    .trim()
    .to_lower()
    .to_owned()
  guard transport == "file" || transport == "smtp" else {
    raise BadRequest(message="transport must be file or smtp")
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
    raise BadRequest(
      message="enter an SMTP hostname or IP address, without a scheme or path",
    )
  }
  let port_text = form.get("smtp_port").unwrap_or("587").trim().to_owned()
  let port = @string.parse_int(port_text) catch {
    _ => raise BadRequest(message="SMTP port must be between 1 and 65535")
  }
  guard port >= 1 && port <= 65535 else {
    raise BadRequest(message="SMTP port must be between 1 and 65535")
  }
  let security = form
    .get("smtp_security")
    .unwrap_or("starttls")
    .trim()
    .to_lower()
    .to_owned()
  guard ["plain", "starttls", "tls"].contains(security) else {
    raise BadRequest(message="SMTP security must be plain, starttls, or tls")
  }
  let auth = form
    .get("smtp_auth")
    .unwrap_or("plain")
    .trim()
    .to_lower()
    .to_owned()
  guard ["none", "plain", "login", "xoauth2"].contains(auth) else {
    raise BadRequest(message="SMTP authentication is invalid")
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
      raise BadRequest(message="SMTP host is required")
    }
    if auth != "none" {
      guard !username.is_empty() else {
        raise BadRequest(message="SMTP username is required")
      }
      guard !password.is_empty() else {
        raise BadRequest(message="SMTP password is required")
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
    raise BadRequest(message="TLS certificate verification setting is invalid")
  }
  let tls_root_cert_file = form
    .get("smtp_tls_root_cert_file")
    .unwrap_or("")
    .trim()
    .to_owned()
  if transport == "smtp" && tls_trust == "custom" {
    guard !tls_root_cert_file.is_empty() else {
      raise BadRequest(message="custom TLS certificate path is required")
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
    raise BadRequest(message="HELO name must be a hostname or address literal")
  }
  guard username.length() <= 1024 &&
    !username.contains("\u0000") &&
    password.length() <= 4096 &&
    !password.contains("\u0000") else {
    raise BadRequest(
      message="SMTP credentials are too long or contain invalid characters",
    )
  }
  guard tls_root_cert_file.length() <= 4096 &&
    !tls_root_cert_file.contains("\u0000") &&
    from.length() <= 320 else {
    raise BadRequest(message="certificate path or From address is invalid")
  }
  if transport == "smtp" {
    guard !helo_name.is_empty() else {
      raise BadRequest(message="HELO name is required")
    }
    guard !from.is_empty() else {
      raise BadRequest(message="From address is required")
    }
    match @core.Mailbox::address_only(from) {
      Ok(_) => ()
      Err(_) => raise BadRequest(message="From address is invalid")
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
        transport as &DbParam,
        host as &DbParam,
        port.to_int64() as &DbParam,
        security as &DbParam,
        auth as &DbParam,
        username as &DbParam,
        password as &DbParam,
        tls_trust as &DbParam,
        tls_root_cert_file as &DbParam,
        helo_name as &DbParam,
        from as &DbParam,
        actor.id as &DbParam,
      ],
    )
  })
}
