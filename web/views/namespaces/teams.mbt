///|
fn require_invitation_id(
  req : @moonback.Request,
) -> Int64 raise @domain.AppError {
  let raw = @web_context.required_param(req, "invitation", "invitation")
  @string.parse_int64(raw) catch {
    _ => raise @domain.BadRequest(message="invalid invitation")
  }
}

///|
pub let teams_module : @moonback.Module = Module(ctx => {
  let asset_path_map = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.get("/-/teams", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let teams = @identity.list_teams(pool, actor)
    res.send_html(render_teams(asset_path_map, actor, teams, None))
  })
  ctx.get("/-/teams/new", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Unauthorized(message="site admin required")
    }
    res.send_html(render_new_team(asset_path_map, actor, None))
  })
  ctx.post("/-/teams", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Unauthorized(message="site admin required")
    }
    let form = @web_context.read_form(req)
    let name_key = @web_context.required_form_value(
      form, "name_key", "team name_key",
    )
    let display_name = @web_context.required_form_value(
      form, "display_name", "team display name",
    )
    if !@domain.valid_name_key(name_key) {
      res.send_html(
        render_new_team(asset_path_map, actor, Some("invalid team name_key")),
        status=400,
      )
    } else if !@identity.create_team(pool, actor, name_key, display_name) {
      res.send_html(
        render_new_team(asset_path_map, actor, Some("team already exists")),
        status=400,
      )
    } else {
      res.send_void(
        status=303,
        headers=@web_context.redirect_headers("/\{name_key}"),
      )
    }
  })
  ctx.post("/:owner/-/invitations", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let team = @web_context.require_organization_namespace(pool, req)
    guard @identity.can_manage_team(pool, actor, team.id) else {
      raise @domain.Forbidden(message="team admin required")
    }
    let form = @web_context.read_form(req)
    let email = @domain.normalize_email(form.get("email").unwrap_or(""))
    let name_key = form.get("name_key").unwrap_or("")
    let display_name = form.get("display_name").unwrap_or("")
    let role = @web_context.optional_form_value(form, "role").unwrap_or(
      "member",
    )
    let bad_message = try {
      let _ = @identity.invite_team_member(
        pool, actor, team, email, name_key, display_name, role,
      )
      None
    } catch {
      @domain.BadRequest(message~) => Some(message)
      err => raise err
    }
    match bad_message {
      Some(message) => {
        let members = @identity.list_team_members(pool, team)
        let invitations = @identity.list_invitations(pool, team)
        let can_manage = @identity.can_manage_team(pool, actor, team.id)
        res.send_html(
          render_team_detail(
            asset_path_map,
            actor,
            team,
            members,
            invitations,
            repositories=@repository.team_repositories(pool, team),
            can_manage~,
            invitation_credentials_csrf=@web_context.request_form_token(
              req,
              "invitation-credentials:\{team.id}",
            ),
            Some(message),
            active_tab="invitations",
            invite_open=true,
            invitation_form=form,
          ),
          status=400,
          headers=@web_context.private_page_headers(),
        )
      }
      None =>
        res.send_void(
          status=303,
          headers=@web_context.redirect_headers(
            "/\{team.name_key}?tab=invitations&notice=invited",
          ),
        )
    }
  })
  ctx.post("/:owner/-/invitations/:invitation/credentials", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    let team = @web_context.require_organization_namespace(pool, req)
    let _ = @web_context.protected_form(
      req,
      "invitation-credentials:\{team.id}",
    )
    let details = @identity.invitation_credentials(
      pool,
      actor,
      team.id,
      require_invitation_id(req),
    )
    res.send_html(
      render_invitation_credentials(asset_path_map, actor, team, details),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/-/invitations/:invitation/revoke", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let team = @web_context.require_organization_namespace(pool, req)
    let invitation_id = require_invitation_id(req)
    let _ = @identity.revoke_invitation(pool, actor, team.id, invitation_id)
    res.send_void(
      status=303,
      headers=@web_context.redirect_headers(
        "/\{team.name_key}?tab=invitations&notice=revoked",
      ),
    )
  })
  ctx.post("/:owner/-/invitations/:invitation/resend", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let team = @web_context.require_organization_namespace(pool, req)
    let invitation_id = require_invitation_id(req)
    let _ = @identity.resend_invitation_email(
      pool,
      actor,
      team.id,
      invitation_id,
    )
    res.send_void(
      status=303,
      headers=@web_context.redirect_headers(
        "/\{team.name_key}?tab=invitations&notice=resent",
      ),
    )
  })
})
