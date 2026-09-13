///|
fn site_settings_module(assets : Map[String, String]) -> @moonback.Module {
  Module(ctx => {
    let pool = db_pool(ctx)
    let addresses = ctx
      .config()
      .get_custom(config_ssh_addresses)
      .unwrap_or(no_ssh_address_config)
    ctx.get("/admin/settings/ssh", async fn(req, res) {
      let actor = require_current_user(req)
      guard actor.is_site_admin else {
        raise Forbidden(message="site administrator required")
      }
      let endpoint = effective_ssh_endpoint(pool, addresses)
      res.send_html(
        render_ssh_settings(
          assets,
          actor,
          request_form_token(req, "site-ssh-settings"),
          addresses,
          endpoint.map(value => value.host).unwrap_or(""),
          endpoint.map(value => value.port.to_string()).unwrap_or("22"),
          None,
          req.query().get("saved") == Some("1"),
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/admin/settings/ssh", async fn(req, res) {
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
              addresses,
              host,
              port,
              Some(message),
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
        headers=private_page_headers(location="/admin/settings/ssh?saved=1"),
      )
    })
  })
}

///|
fn render_ssh_settings(
  assets : Map[String, String],
  user : CurrentUser,
  csrf : String,
  config : SshAddressConfig,
  host : String,
  port : String,
  error : String?,
  saved : Bool,
) -> @moonback.Html {
  let preview = SshEndpoint::from_fields(host, port).clone_url({
    owner: "team",
    name: "repository",
  }) catch {
    _ => "Not configured"
  }
  let locked = config.public_override is Some(_)
  layout(
    "SSH access",
    assets,
    Html(b => {
      b <+ "<section class=\"ssh-address-settings\"><h1>SSH access</h1>"
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
        "<form class=\"form-stack\" data-ssh-address-form method=\"post\" action=\"/admin/settings/ssh\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><fieldset class=\"ssh-address-fields\""
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
    }),
    head_end=repository_assets_head(assets),
    current_user=Some(user),
  )
}
