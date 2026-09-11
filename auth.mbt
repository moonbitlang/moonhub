///|
let session_cookie_name : String = "moonhub_session"

///|
fn parse_form(body : String) -> Map[String, String] {
  let values : Map[String, String] = Map([])
  for parsed = 0 {
    let pair_end = if body[parsed:].find("&") is Some(pair_end) {
      parsed + pair_end
    } else {
      body.length()
    }
    let pair = body[parsed:pair_end]
    if !pair.is_empty() {
      let (name, value) = parse_form_pair(pair)
      values[name] = value
    }
    if pair_end == body.length() {
      break
    } else {
      continue pair_end + 1
    }
  }
  values
}

///|
fn parse_form_pair(pair : StringView) -> (String, String) {
  match pair.split_once("=") {
    Some((name, value)) => (percent_decode(name), percent_decode(value))
    None => (percent_decode(pair), "")
  }
}

///|
fn required_form_value(
  form : Map[String, String],
  name : String,
  label : String,
) -> String raise AppError {
  match form.get(name) {
    Some(value) if !value.is_empty() => value
    _ => raise BadRequest(message="missing \{label}")
  }
}

///|
fn optional_form_value(form : Map[String, String], name : String) -> String? {
  match form.get(name) {
    Some(value) if !value.is_empty() => Some(value)
    _ => None
  }
}

///|
fn redirect_headers(location : String) -> @moonback.Headers {
  @moonback.Headers::from({ "location": location })
}

///|
fn session_cookie(token : String) -> @http.Cookie {
  Cookie(session_cookie_name, token, path="/", http_only=true, extensions=[
    "SameSite=Lax",
  ])
}

///|
fn clear_session_cookie() -> @http.Cookie {
  Cookie(session_cookie_name, "", path="/", max_age=0, http_only=true, extensions=[
    "SameSite=Lax",
  ])
}

///|
fn login_headers(token : String, location : String) -> @moonback.Headers {
  let headers = @moonback.MutHeaders()
  headers.set("location", location)
  headers.add_set_cookie(session_cookie(token))
  headers.to_immut()
}

///|
fn logout_headers() -> @moonback.Headers {
  let headers = @moonback.MutHeaders()
  headers.set("location", "/login")
  headers.add_set_cookie(clear_session_cookie())
  headers.to_immut()
}

///|
fn current_user_from_request(req : @moonback.Request) -> CurrentUser? {
  req.ctx.get_userdata(current_user_key)
}

///|
fn current_invitation_from_request(
  req : @moonback.Request,
) -> InvitationSession? {
  req.ctx.get_userdata(invitation_session_key)
}

///|
fn require_current_user(req : @moonback.Request) -> CurrentUser raise AppError {
  match current_user_from_request(req) {
    Some(user) => user
    None => raise Unauthorized(message="login required")
  }
}

///|
fn require_invitation_session(
  req : @moonback.Request,
) -> InvitationSession raise AppError {
  match current_invitation_from_request(req) {
    Some(session) => session
    None => raise Unauthorized(message="invitation login required")
  }
}

///|
extenum @moonback.TypedBox += {
  RequestUser(CurrentUser)
  RequestInvitationSession(InvitationSession)
}

///|
let current_user_key : @moonback.TypedKey[CurrentUser] = TypedKey(
  name="moonhub.current_user",
  box=user => RequestUser(user),
  unbox=err => {
    match err {
      RequestUser(user) => Some(user)
      _ => None
    }
  },
)

///|
let invitation_session_key : @moonback.TypedKey[InvitationSession] = TypedKey(
  name="moonhub.invitation_session",
  box=session => RequestInvitationSession(session),
  unbox=err => {
    match err {
      RequestInvitationSession(session) => Some(session)
      _ => None
    }
  },
)

///|
fn auth_middleware(pool : @pgpool.Pool) -> @moonback.Middleware {
  Middleware(next => {
    (req, res) => {
      match req.cookie().get(session_cookie_name) {
        Some(token) =>
          match lookup_session_user(pool, token) {
            Some(user) => req.ctx.set_userdata(current_user_key, user)
            None =>
              match lookup_invitation_session(pool, token) {
                Some(session) =>
                  req.ctx.set_userdata(invitation_session_key, session)
                None => ()
              }
          }
        None => ()
      }
      next(req, res)
    }
  })
}

///|
fn require_login_middleware() -> @moonback.Middleware {
  Middleware(next => {
    (req, res) => {
      if req.path == "/login" {
        next(req, res)
      } else if current_invitation_from_request(req) is Some(_) {
        if req.path == "/change-password" || req.path == "/logout" {
          next(req, res)
        } else {
          res.send_void(
            status=303,
            headers=redirect_headers("/change-password"),
          )
        }
      } else {
        match current_user_from_request(req) {
          Some(_) => next(req, res)
          None => res.send_void(status=303, headers=redirect_headers("/login"))
        }
      }
    }
  })
}

///|
fn auth_module(asset_path_map : Map[String, String]) -> @moonback.Module {
  Module(ctx => {
    let pool = db_pool(ctx)
    ctx.get("/login", async fn(req, res) {
      match current_user_from_request(req) {
        Some(_) => res.send_void(status=303, headers=redirect_headers("/"))
        None =>
          match current_invitation_from_request(req) {
            Some(_) =>
              res.send_void(
                status=303,
                headers=redirect_headers("/change-password"),
              )
            None => res.send_html(render_login(asset_path_map, None))
          }
      }
    })
    ctx.post("/login", async fn(req, res) {
      let form = parse_form(req.body.text())
      let name_key = required_form_value(form, "name_key", "name_key")
      let password = required_form_value(form, "password", "password")
      match authenticate_user(pool, name_key, password) {
        Some(login) => {
          let location = if login.invitation is Some(_) {
            "/change-password"
          } else {
            "/"
          }
          res.send_void(
            status=303,
            headers=login_headers(login.token, location),
          )
        }
        None =>
          res.send_html(
            render_login(asset_path_map, Some("invalid username or password")),
            status=401,
          )
      }
    })
    ctx.get("/change-password", async fn(req, res) {
      match current_user_from_request(req) {
        Some(user) =>
          res.send_html(
            render_change_password(asset_path_map, user, None, false),
          )
        None => {
          let invitation = require_invitation_session(req)
          res.send_html(
            render_invitation_password(asset_path_map, invitation, None),
          )
        }
      }
    })
    ctx.post("/change-password", async fn(req, res) {
      let form = parse_form(req.body.text())
      let new_password = required_form_value(
        form, "new_password", "new password",
      )
      let confirm_password = required_form_value(
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
      } else {
        match current_invitation_from_request(req) {
          Some(invitation_session) =>
            match accept_invitation(pool, invitation_session, new_password) {
              Some(login) =>
                res.send_void(
                  status=303,
                  headers=login_headers(login.token, "/"),
                )
              None =>
                res.send_html(
                  render_invitation_password(
                    asset_path_map,
                    invitation_session,
                    Some("invitation is no longer valid"),
                  ),
                  status=400,
                )
            }
          None =>
            raise BadRequest(
              message="password change is only required for invitations",
            )
        }
      }
    })
    ctx.post("/logout", async fn(req, res) {
      match req.cookie().get(session_cookie_name) {
        Some(token) => revoke_session(pool, token)
        None => ()
      }
      res.send_void(status=303, headers=logout_headers())
    })
  })
}

///|
async fn render_password_error(
  pool : @pgpool.Pool,
  req : @moonback.Request,
  res : @moonback.Responder,
  asset_path_map : Map[String, String],
  message : String,
) -> Unit {
  let _ = pool
  match current_invitation_from_request(req) {
    Some(invitation) =>
      res.send_html(
        render_invitation_password(asset_path_map, invitation, Some(message)),
        status=400,
      )
    None => raise BadRequest(message~)
  }
}
