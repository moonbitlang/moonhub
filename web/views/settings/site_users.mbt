///|
const SITE_USERS_PATH : String = "/-/admin/settings/users"

///|
fn site_user_promotion_path(user_id : Int64) -> String {
  "\{SITE_USERS_PATH}/\{user_id}/promote"
}

///|
let site_users_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.get(SITE_USERS_PATH, async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    let username = req
      .query()
      .get("username")
      .map(value => value.trim().to_owned())
    let target = if username is Some(name) && !name.is_empty() {
      Some(@identity.active_user_by_name(pool, name)) catch {
        @domain.NotFound(_) => None
        err => raise err
      }
    } else {
      None
    }
    let csrf = if target is Some(user) && !user.is_site_admin {
      Some(
        @web_context.request_form_token(req, site_user_promotion_path(user.id)),
      )
    } else {
      None
    }
    res.send_html(
      render_site_users(
        assets,
        actor,
        username,
        target,
        csrf,
        req.query().get("granted") == Some("1"),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post(SITE_USERS_PATH + "/:user/promote", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    let user_id = @string.parse_int64(
      @web_context.required_param(req, "user", "user ID"),
    ) catch {
      _ => raise @domain.NotFound(message="active user not found")
    }
    guard user_id > 0L else {
      raise @domain.NotFound(message="active user not found")
    }
    let _ = @web_context.protected_form(req, site_user_promotion_path(user_id))
    let username = @identity.grant_site_admin(pool, actor, user_id)
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location="\{SITE_USERS_PATH}?username=\{@web_context.url_escape_path(username)}&granted=1",
      ),
    )
  })
})

///|
fn render_site_users(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  username : String?,
  target : @domain.CurrentUser?,
  csrf : String?,
  granted : Bool,
) -> @moonback.Html {
  @web_ui.layout(
    "Users",
    assets,
    Html(b => {
      b <+
        $|<div class="page-heading"><div>
        $|  <h1 id="site-users-heading">Users</h1>
        $|  <p class="page-subtitle">Find a user by username to grant site administrator access.</p>
        $|</div></div>
        $|<div class="form-page"><div class="panel">
        $|  <search aria-label="Find a user">
        $|    <form class="list-filters site-user-search" method="get" action="\{SITE_USERS_PATH}" aria-labelledby="site-users-heading">
        $|      <div class="field">
        $|        <label for="site-user-name">Username</label>
        $|        <input id="site-user-name" name="username" type="search" value="\{username.unwrap_or("")}" maxlength="63" autocomplete="off" autocorrect="off" autocapitalize="none" spellcheck="false" required>
        $|      </div>
        $|      <button class="secondary-button" type="submit">Find user</button>
        $|    </form>
        $|  </search>
      if target is Some(user) {
        let role = if user.is_site_admin {
          "Site administrator"
        } else {
          "User"
        }
        if granted && user.is_site_admin {
          b <+
            #|<p class="settings-success" role="status">Site administrator access granted.</p>
        }
        b <+
          $|<section class="content-stack">
          $|  <div>
          $|    <h2 id="site-user-account">\{user.display_name}</h2>
          $|    <p class="page-subtitle"><code>@\{user.name_key}</code> <span class="metadata-separator" aria-hidden="true">·</span> \{role}</p>
          $|  </div>
        if csrf is Some(token) {
          b <+
            $|<form method="post" action="\{site_user_promotion_path(user.id)}" aria-labelledby="site-user-account">
            $|  <input type="hidden" name="csrf_token" value="\{token}">
            $|  <p id="site-admin-grant-scope" class="muted">Site administrators can manage all repositories and site settings.</p>
            $|  <button type="submit" aria-describedby="site-admin-grant-scope">Make site administrator</button>
            $|</form>
        }
        b <+ "</section>"
      } else if username is Some(name) {
        let message = if name.is_empty() {
          "Enter a username."
        } else {
          "No active user found. Check the username and try again."
        }
        b <+
          $|<p class="settings-notice" role="status">\{message}</p>
      }
      b <+ "</div></div>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.SiteNavigation("users"),
  )
}
