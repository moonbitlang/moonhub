///|
pub let site_settings_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let addresses = ctx.require(@web_context.config_ssh_addresses)
  ctx.get("/-/admin/settings/ssh", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    let endpoint = @repository.effective_ssh_endpoint(pool, addresses)
    let mail = @mail.load_mail_settings(pool)
    res.send_html(
      render_ssh_settings(
        assets,
        actor,
        @web_context.request_form_token(req, "site-ssh-settings"),
        @web_context.request_form_token(req, "site-mail-settings"),
        addresses,
        endpoint.map(value => value.host).unwrap_or(""),
        endpoint.map(value => value.port.to_string()).unwrap_or("22"),
        None,
        req.query().get("saved") == Some("1"),
        mail,
        None,
        req.query().get("saved_mail") == Some("1"),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/-/admin/settings/ssh", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    let form = @web_context.protected_form(req, "site-ssh-settings")
    let host = form.get("host").unwrap_or("")
    let port = form.get("port").unwrap_or("")
    @repository.save_ssh_endpoint(pool, actor, addresses, host, port) catch {
      @domain.BadRequest(message~) => {
        res.send_html(
          render_ssh_settings(
            assets,
            actor,
            @web_context.request_form_token(req, "site-ssh-settings"),
            @web_context.request_form_token(req, "site-mail-settings"),
            addresses,
            host,
            port,
            Some(message),
            false,
            @mail.load_mail_settings(pool),
            None,
            false,
          ),
          status=400,
          headers=@web_context.private_page_headers(),
        )
        return
      }
      err => raise err
    }
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location="/-/admin/settings/ssh?saved=1",
      ),
    )
  })
  ctx.post("/-/admin/settings/mail", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    let form = @web_context.protected_form(req, "site-mail-settings")
    let existing = @mail.load_mail_settings(pool)
    @mail.save_mail_settings(pool, actor, form, existing) catch {
      @domain.BadRequest(message~) => {
        let endpoint = @repository.effective_ssh_endpoint(pool, addresses)
        res.send_html(
          render_ssh_settings(
            assets,
            actor,
            @web_context.request_form_token(req, "site-ssh-settings"),
            @web_context.request_form_token(req, "site-mail-settings"),
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
          headers=@web_context.private_page_headers(),
        )
        return
      }
      err => raise err
    }
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location="/-/admin/settings/ssh?saved_mail=1",
      ),
    )
  })
})

///|
fn render_ssh_settings(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  csrf : String,
  mail_csrf : String,
  config : @repository.SshAddressConfig,
  host : String,
  port : String,
  error : String?,
  saved : Bool,
  mail : @mail.MailSettings,
  mail_error : String?,
  mail_saved : Bool,
  mail_form? : Map[String, String],
) -> @moonback.Html {
  let preview = @repository.SshEndpoint::from_fields(host, port).clone_url({
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
  @web_ui.layout(
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
    head_end=@web_assets.repository_assets_head(assets),
    current_user=Some(user),
    navigation=@web_ui.SiteNavigation("ssh"),
  )
}
