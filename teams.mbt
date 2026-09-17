///|
fn require_team_name_key(req : @moonback.Request) -> String raise AppError {
  let name_key = req.required_param("team", "team")
  guard valid_name_key(name_key) else {
    raise BadRequest(message="invalid team")
  }
  name_key
}

///|
fn require_invitation_id(req : @moonback.Request) -> Int64 raise AppError {
  let raw = req.required_param("invitation", "invitation")
  @string.parse_int64(raw) catch {
    _ => raise BadRequest(message="invalid invitation")
  }
}

///|
fn require_team_by_request(
  pool : Database,
  req : @moonback.Request,
) -> TeamSummary raise {
  let name_key = require_team_name_key(req)
  match get_team_by_name_key(pool, name_key) {
    Some(team) => team
    None => raise NotFound(message="team not found")
  }
}

///|
fn require_team_member_access(
  pool : Database,
  actor : CurrentUser,
  team : TeamSummary,
) -> Unit raise {
  if actor.is_site_admin {
    ()
  } else {
    match team_role(pool, actor, team.id) {
      Some(_) => ()
      None => raise Forbidden(message="team access required")
    }
  }
}

///|
fn teams_module(asset_path_map : Map[String, String]) -> @moonback.Module {
  Module(ctx => {
    let pool = db_pool(ctx)
    ctx.get("/-/teams", async fn(req, res) {
      let actor = require_current_user(req)
      let teams = list_teams(pool, actor)
      res.send_html(render_teams(asset_path_map, actor, teams, None))
    })
    ctx.get("/-/teams/new", async fn(req, res) {
      let actor = require_current_user(req)
      guard actor.is_site_admin else {
        raise Unauthorized(message="site admin required")
      }
      res.send_html(render_new_team(asset_path_map, actor, None))
    })
    ctx.post("/-/teams", async fn(req, res) {
      let actor = require_current_user(req)
      guard actor.is_site_admin else {
        raise Unauthorized(message="site admin required")
      }
      let form = read_form(req)
      let name_key = required_form_value(form, "name_key", "team name_key")
      let display_name = required_form_value(
        form, "display_name", "team display name",
      )
      if !valid_name_key(name_key) {
        res.send_html(
          render_new_team(asset_path_map, actor, Some("invalid team name_key")),
          status=400,
        )
      } else if !create_team(pool, actor, name_key, display_name) {
        res.send_html(
          render_new_team(asset_path_map, actor, Some("team already exists")),
          status=400,
        )
      } else {
        res.send_void(
          status=303,
          headers=redirect_headers("/teams/\{name_key}"),
        )
      }
    })
    ctx.get("/teams/:team", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      require_team_member_access(pool, actor, team)
      let members = list_team_members(pool, team)
      let invitations = list_invitations(pool, team)
      let can_manage = can_manage_team(pool, actor, team.id)
      let active_tab = req.query().get("tab").unwrap_or("repositories")
      guard ["repositories", "members", "invitations"].contains(active_tab) else {
        raise BadRequest(message="invalid team view")
      }
      res.send_html(
        render_team_detail(
          asset_path_map,
          actor,
          team,
          members,
          invitations,
          repositories=team_repositories(pool, team),
          can_manage~,
          invitation_credentials_csrf=request_form_token(
            req,
            "invitation-credentials:\{team.id}",
          ),
          None,
          active_tab~,
          invite_open=req.query().get("invite") == Some("1"),
          notice=match req.query().get("notice") {
            Some("invited") => Some("Invitation created.")
            Some("revoked") => Some("Invitation revoked.")
            Some("resent") => Some("Invitation email queued.")
            _ => None
          },
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/teams/:team/invitations", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      guard can_manage_team(pool, actor, team.id) else {
        raise Forbidden(message="team admin required")
      }
      let form = read_form(req)
      let email = normalize_email(form.get("email").unwrap_or(""))
      let name_key = form.get("name_key").unwrap_or("")
      let display_name = form.get("display_name").unwrap_or("")
      let role = optional_form_value(form, "role").unwrap_or("member")
      let bad_message = try {
        let _ = invite_team_member(
          pool, actor, team, email, name_key, display_name, role,
        )
        None
      } catch {
        BadRequest(message~) => Some(message)
        err => raise err
      }
      match bad_message {
        Some(message) => {
          let members = list_team_members(pool, team)
          let invitations = list_invitations(pool, team)
          let can_manage = can_manage_team(pool, actor, team.id)
          res.send_html(
            render_team_detail(
              asset_path_map,
              actor,
              team,
              members,
              invitations,
              repositories=team_repositories(pool, team),
              can_manage~,
              invitation_credentials_csrf=request_form_token(
                req,
                "invitation-credentials:\{team.id}",
              ),
              Some(message),
              active_tab="invitations",
              invite_open=true,
              invitation_form=form,
            ),
            status=400,
            headers=private_page_headers(),
          )
        }
        None =>
          res.send_void(
            status=303,
            headers=redirect_headers(
              "/teams/\{team.name_key}?tab=invitations&notice=invited",
            ),
          )
      }
    })
    ctx.post("/teams/:team/invitations/:invitation/credentials", async fn(
      req,
      res,
    ) {
      let actor = require_current_user(req)
      guard actor.is_site_admin else {
        raise Forbidden(message="site administrator required")
      }
      let team = require_team_by_request(pool, req)
      let _ = protected_form(req, "invitation-credentials:\{team.id}")
      let details = invitation_credentials(
        pool,
        actor,
        team.id,
        require_invitation_id(req),
      )
      res.send_html(
        render_invitation_credentials(asset_path_map, actor, team, details),
        headers=private_page_headers(),
      )
    })
    ctx.post("/teams/:team/invitations/:invitation/revoke", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      let invitation_id = require_invitation_id(req)
      let _ = revoke_invitation(pool, actor, team.id, invitation_id)
      res.send_void(
        status=303,
        headers=redirect_headers(
          "/teams/\{team.name_key}?tab=invitations&notice=revoked",
        ),
      )
    })
    ctx.post("/teams/:team/invitations/:invitation/resend", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      let invitation_id = require_invitation_id(req)
      let _ = resend_invitation_email(pool, actor, team.id, invitation_id)
      res.send_void(
        status=303,
        headers=redirect_headers(
          "/teams/\{team.name_key}?tab=invitations&notice=resent",
        ),
      )
    })
  })
}
