///|
let recovery_cookie_name = "moonhub_recovery"

///|
fn recovery_form_context(
  req : @moonback.Request,
) -> (String, @moonback.Headers) {
  let secret = req
    .cookie()
    .get(recovery_cookie_name)
    .unwrap_or_else(() => @identity.random_hex(32))
  let headers = @web_context.private_page_headers().to_mut()
  headers.set("referrer-policy", "no-referrer")
  headers.add_set_cookie(
    @http.Cookie(
      recovery_cookie_name,
      secret,
      path="/-/",
      max_age=1800,
      http_only=true,
      extensions=["SameSite=Strict"],
    ),
  )
  (
    @web_context.form_csrf_token(secret, "password-recovery"),
    headers.to_immut(),
  )
}

///|
async fn read_recovery_form(req : @moonback.Request) -> Map[String, String] {
  guard req.headers.get("Sec-Fetch-Site") != Some("cross-site") else {
    raise @domain.Forbidden(message="cross-site request rejected")
  }
  let form = @web_context.read_form(req)
  guard req.cookie().get(recovery_cookie_name) is Some(secret) &&
    @web_context.valid_form_token(
      @web_context.form_csrf_token(secret, "password-recovery"),
      form.get("csrf_token").unwrap_or(""),
    ) else {
    raise @domain.Forbidden(
      message="invalid request token; reload the page and try again",
    )
  }
  form
}

///|
let password_recovery_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.get("/-/forgot-password", async fn(req, res) {
    let (csrf, headers) = recovery_form_context(req)
    res.send_html(render_forgot_password(assets, csrf, "", None), headers~)
  })
  ctx.post("/-/forgot-password", async fn(req, res) {
    let form = read_recovery_form(req)
    let email = @domain.normalize_email(form.get("email").unwrap_or(""))
    let (csrf, headers) = recovery_form_context(req)
    if !@domain.valid_email(email) || email.length() > 254 {
      res.send_html(
        render_forgot_password(
          assets,
          csrf,
          email,
          Some("Enter a valid email address."),
        ),
        status=400,
        headers~,
      )
    } else {
      @identity.request_password_reset(pool, email)
      res.send_html(
        render_reset_password(assets, csrf, email, "", None, true),
        headers~,
      )
    }
  })
  ctx.get("/-/reset-password", async fn(req, res) {
    let (csrf, headers) = recovery_form_context(req)
    res.send_html(
      render_reset_password(assets, csrf, "", "", None, false),
      headers~,
    )
  })
  ctx.post("/-/reset-password", async fn(req, res) {
    let form = read_recovery_form(req)
    let email = @domain.normalize_email(form.get("email").unwrap_or(""))
    let code = form.get("code").unwrap_or("").trim().to_owned()
    let password = form.get("new_password").unwrap_or("")
    let error = if password != form.get("confirm_password").unwrap_or("") {
      Some("New passwords do not match.")
    } else {
      @identity.new_password_error(password)
    }
    let error = match error {
      Some(_) => error
      None =>
        if @identity.reset_password(pool, email, code, password) {
          None
        } else {
          Some(
            "Invalid or expired reset code. Check your email and code, or request a new one.",
          )
        }
    }
    match error {
      Some(message) => {
        let (csrf, headers) = recovery_form_context(req)
        res.send_html(
          render_reset_password(assets, csrf, email, code, Some(message), false),
          status=400,
          headers~,
        )
      }
      None => {
        let headers = @web_context.private_page_headers().to_mut()
        for (name, value) in @web_context.logout_headers().iter() {
          headers.add(name, value)
        }
        headers.remove("location")
        headers.set("referrer-policy", "no-referrer")
        headers.add_set_cookie(
          @http.Cookie(
            recovery_cookie_name,
            "",
            path="/-/",
            max_age=0,
            http_only=true,
            extensions=["SameSite=Strict"],
          ),
        )
        res.send_html(render_password_reset_success(assets), headers~)
      }
    }
  })
})
