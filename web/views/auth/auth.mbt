///|
pub let auth_module : @moonback.Module = Module(ctx => {
  ctx.use_(password_recovery_module)
  let asset_path_map = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.get("/-/login", async fn(req, res) {
    if @web_context.current_user_from_request(req) is Some(_) {
      res.send_void(status=303, headers=@web_context.redirect_headers("/"))
    } else if @web_context.current_invitation_from_request(req) is Some(_) {
      res.send_void(
        status=303,
        headers=@web_context.redirect_headers("/-/change-password"),
      )
    } else {
      res.send_html(render_login(asset_path_map, None))
    }
  })
  ctx.post("/-/login", async fn(req, res) {
    let form = @web_context.read_form(req)
    let identifier = @web_context.required_form_value(
        form, "name_key", "username or email",
      )
      .trim()
      .to_owned()
    let password = @web_context.required_form_value(
      form, "password", "password",
    )
    if @identity.authenticate_user(pool, identifier, password) is Some(login) {
      let location = if login.invitation is Some(_) {
        "/-/change-password"
      } else {
        "/"
      }
      res.send_void(
        status=303,
        headers=@web_context.login_headers(login.token, location),
      )
    } else {
      res.send_html(
        render_login(
          asset_path_map,
          Some("Invalid username, email, or password."),
          identifier~,
        ),
        status=401,
      )
    }
  })
  ctx.get("/-/change-password", async fn(req, res) {
    if @web_context.current_user_from_request(req) is Some(user) {
      res.send_html(render_change_password(asset_path_map, user, None, false))
    } else {
      let invitation = @web_context.require_invitation_session(req)
      res.send_html(
        render_invitation_password(asset_path_map, invitation, None),
      )
    }
  })
  ctx.post("/-/change-password", async fn(req, res) {
    let form = @web_context.read_form(req)
    let new_password = @web_context.required_form_value(
      form, "new_password", "new password",
    )
    let confirm_password = @web_context.required_form_value(
      form, "confirm_password", "password confirmation",
    )
    if new_password != confirm_password {
      render_password_error(
        pool, req, res, asset_path_map, "new passwords do not match",
      )
    } else if new_password.length() < 8 {
      render_password_error(
        pool, req, res, asset_path_map, "new password must be at least 8 characters",
      )
    } else if @web_context.current_invitation_from_request(req)
      is Some(invitation_session) {
      if @identity.accept_invitation(pool, invitation_session, new_password)
        is Some(login) {
        res.send_void(
          status=303,
          headers=@web_context.login_headers(login.token, "/"),
        )
      } else {
        res.send_html(
          render_invitation_password(
            asset_path_map,
            invitation_session,
            Some("invitation is no longer valid"),
          ),
          status=400,
        )
      }
    } else {
      raise @domain.BadRequest(
        message="password change is only required for invitations",
      )
    }
  })
  ctx.post("/-/logout", async fn(req, res) {
    if req.cookie().get(@web_context.session_cookie_name) is Some(token) {
      @identity.revoke_session(pool, token)
    }
    res.send_void(status=303, headers=@web_context.logout_headers())
  })
})

///|
async fn render_password_error(
  pool : @database.Database,
  req : @moonback.Request,
  res : @moonback.Responder,
  asset_path_map : Map[String, String],
  message : String,
) -> Unit {
  let _ = pool
  if @web_context.current_invitation_from_request(req) is Some(invitation) {
    res.send_html(
      render_invitation_password(asset_path_map, invitation, Some(message)),
      status=400,
    )
  } else {
    raise @domain.BadRequest(message~)
  }
}
