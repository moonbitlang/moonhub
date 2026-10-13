///|
fn token_page(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  tokens : Array[@identity.AccessToken],
  csrf : String,
  created : String?,
  error : String?,
  submitted~ : Map[String, String] = Map([]),
) -> @moonback.Html {
  @web_ui.layout(
    "Access tokens",
    assets,
    Html(b => {
      b <+
        "<h1>Access tokens</h1><p class=\"page-subtitle\">Connect the Moonhub CLI and scripts to your account.</p>"
      if error is Some(error) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{error}</p>"
      }
      if created is Some(token) {
        b <+
          "<section class=\"settings-notice\" aria-label=\"New access token\"><h2>Copy your token now</h2><p>This token is shown once. Store it in a private file for CLI login.</p><label class=\"field\"><span>Token</span><input value=\"\{token}\" readonly autocomplete=\"off\" spellcheck=\"false\"></label></section>"
      }
      b <+ "<ul class=\"mr-list\">"
      for token in tokens {
        b <+
          "<li><strong>\{token.name}</strong><p class=\"muted\">\{token.permission} · expires \{token.expires_at} · \{if token.revoked_at is Some(_) { "Revoked" } else { "Not revoked" }}</p>"
        if token.revoked_at is None {
          b <+
            "<form method=\"post\" action=\"/-/settings/tokens/\{token.id.to_string()}/revoke\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button class=\"danger-button secondary-button\" type=\"submit\">Revoke \{token.name}</button></form>"
        }
        b <+ "</li>"
      }
      if tokens.is_empty() {
        b <+ "<li class=\"muted\">No access tokens.</li>"
      }
      b <+
        "</ul><form class=\"form-stack mr-form\" method=\"post\" action=\"/-/settings/tokens\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><label class=\"field\"><span>Name</span><input name=\"name\" value=\"\{submitted.get("name").unwrap_or("")}\" required maxlength=\"100\"></label><label class=\"field\"><span>Permission</span><select aria-label=\"Permission\" name=\"permission\">"
      for
        (value, label) in [
          ("read", "Read only"),
          ("write", "Read and collaboration writes"),
          ("execute", "Collaboration writes and CI execution"),
          ("merge", "Collaboration writes and merge submission"),
        ] {
        b <+ "<option value=\"\{value}\""
        if submitted.get("permission").unwrap_or("read") == value {
          b <+ " selected"
        }
        b <+ ">\{label}</option>"
      }
      b <+
        "</select></label><label class=\"field\"><span>Expires in days</span><input type=\"number\" name=\"days\" min=\"1\" max=\"365\" value=\"\{submitted.get("days").unwrap_or("30")}\" required></label><div><button type=\"submit\">Create token</button></div></form>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.AccountNavigation("tokens"),
  )
}

///|
pub let tokens_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  let assets = ctx.require(@web_context.asset_paths_key)
  ctx.get("/-/settings/tokens", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    res.send_html(
      token_page(
        assets,
        actor,
        @identity.access_tokens(pool, actor),
        @web_context.request_form_token(req, "access-tokens"),
        None,
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/-/settings/tokens", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let form = @web_context.protected_form(req, "access-tokens")
    let result = @identity.create_access_token(
      pool,
      actor,
      form.get("name").unwrap_or(""),
      form.get("permission").unwrap_or("read"),
      @string.parse_int(form.get("days").unwrap_or("")) catch {
        _ => raise @domain.BadRequest(message="invalid expiry")
      },
    ) catch {
      @domain.BadRequest(message~) => {
        res.send_html(
          token_page(
            assets,
            actor,
            @identity.access_tokens(pool, actor),
            @web_context.request_form_token(req, "access-tokens"),
            None,
            Some(message),
            submitted=form,
          ),
          status=400,
          headers=@web_context.private_page_headers(),
        )
        return
      }
      err => raise err
    }
    res.send_html(
      token_page(
        assets,
        actor,
        @identity.access_tokens(pool, actor),
        @web_context.request_form_token(req, "access-tokens"),
        Some(result),
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/-/settings/tokens/:id/revoke", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    ignore(@web_context.protected_form(req, "access-tokens"))
    @identity.revoke_access_token(
      pool,
      actor,
      @web_context.positive_resource_number(
        @web_context.required_param(req, "id", "token"),
      ),
    )
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(location="/-/settings/tokens"),
    )
  })
})
