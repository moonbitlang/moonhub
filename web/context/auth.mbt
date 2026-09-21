///|
pub let session_cookie_name : String = "moonhub_session"

///|
pub fn parse_form(body : String) -> Map[String, String] {
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
pub fn required_form_value(
  form : Map[String, String],
  name : String,
  label : String,
) -> String raise @domain.AppError {
  match form.get(name) {
    Some(value) if !value.is_empty() => value
    _ => raise @domain.BadRequest(message="missing \{label}")
  }
}

///|
pub fn optional_form_value(
  form : Map[String, String],
  name : String,
) -> String? {
  match form.get(name) {
    Some(value) if !value.is_empty() => Some(value)
    _ => None
  }
}

///|
pub fn redirect_headers(location : String) -> @moonback.Headers {
  @moonback.Headers::from({ "location": location })
}

///|
pub fn session_cookie(token : String) -> @http.Cookie {
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
pub fn login_headers(token : String, location : String) -> @moonback.Headers {
  let headers = @moonback.MutHeaders()
  headers.set("location", location)
  headers.add_set_cookie(session_cookie(token))
  headers.to_immut()
}

///|
pub fn logout_headers() -> @moonback.Headers {
  let headers = @moonback.MutHeaders()
  headers.set("location", "/-/login")
  headers.add_set_cookie(clear_session_cookie())
  headers.to_immut()
}

///|
pub fn current_user_from_request(
  req : @moonback.Request,
) -> @domain.CurrentUser? {
  req.ctx.get_userdata(current_user_key)
}

///|
pub fn current_invitation_from_request(
  req : @moonback.Request,
) -> @identity.InvitationSession? {
  req.ctx.get_userdata(invitation_session_key)
}

///|
pub fn require_current_user(
  req : @moonback.Request,
) -> @domain.CurrentUser raise @domain.AppError {
  match current_user_from_request(req) {
    Some(user) => user
    None => raise @domain.Unauthorized(message="login required")
  }
}

///|
pub fn require_invitation_session(
  req : @moonback.Request,
) -> @identity.InvitationSession raise @domain.AppError {
  match current_invitation_from_request(req) {
    Some(session) => session
    None => raise @domain.Unauthorized(message="invitation login required")
  }
}

///|
extenum @moonback.TypedBox += {
  RequestUser(@domain.CurrentUser)
  RequestInvitationSession(@identity.InvitationSession)
}

///|
let current_user_key : @moonback.TypedKey[@domain.CurrentUser] = TypedKey(
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
let invitation_session_key : @moonback.TypedKey[@identity.InvitationSession] = TypedKey(
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
pub fn auth_middleware(pool : @database.Database) -> @moonback.Middleware {
  Middleware(next => {
    (req, res) => {
      match req.cookie().get(session_cookie_name) {
        Some(token) =>
          match @identity.lookup_session_user(pool, token) {
            Some(user) => req.ctx.set_userdata(current_user_key, user)
            None =>
              match @identity.lookup_invitation_session(pool, token) {
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
pub fn require_login_middleware() -> @moonback.Middleware {
  Middleware(next => {
    (req, res) => {
      if req.path == "/-/login" ||
        req.path == "/-/forgot-password" ||
        req.path == "/-/reset-password" {
        next(req, res)
      } else if current_invitation_from_request(req) is Some(_) {
        if req.path == "/-/change-password" || req.path == "/-/logout" {
          next(req, res)
        } else {
          res.send_void(
            status=303,
            headers=redirect_headers("/-/change-password"),
          )
        }
      } else {
        match current_user_from_request(req) {
          Some(_) => next(req, res)
          None =>
            res.send_void(status=303, headers=redirect_headers("/-/login"))
        }
      }
    }
  })
}
