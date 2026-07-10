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
async fn require_team_by_request(
  pool : @pgpool.Pool,
  req : @moonback.Request,
) -> TeamSummary {
  let name_key = require_team_name_key(req)
  match get_team_by_name_key(pool, name_key) {
    Some(team) => team
    None => raise NotFound(message="team not found")
  }
}

///|
async fn require_team_member_access(
  pool : @pgpool.Pool,
  actor : CurrentUser,
  team : TeamSummary,
) -> Unit {
  if actor.is_site_admin {
    ()
  } else {
    match team_role(pool, actor, team.id) {
      Some(_) => ()
      None => raise Unauthorized(message="team access required")
    }
  }
}

///|
fn teams_module(asset_path_map : Map[String, String]) -> @moonback.Module {
  Module(ctx => {
    let pool = db_pool(ctx)
    ctx.get("/teams", async fn(req, res) {
      let actor = require_current_user(req)
      let teams = list_teams(pool, actor)
      res.send_html(render_teams(asset_path_map, actor, teams, None))
    })
    ctx.get("/teams/new", async fn(req, res) {
      let actor = require_current_user(req)
      guard actor.is_site_admin else {
        raise Unauthorized(message="site admin required")
      }
      res.send_html(render_new_team(asset_path_map, actor, None))
    })
    ctx.post("/teams", async fn(req, res) {
      let actor = require_current_user(req)
      guard actor.is_site_admin else {
        raise Unauthorized(message="site admin required")
      }
      let form = parse_form(req.body.text())
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
      res.send_html(
        render_team_detail(
          asset_path_map,
          actor,
          team,
          members,
          invitations,
          can_manage~,
          None,
        ),
      )
    })
    ctx.post("/teams/:team/invitations", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      let form = parse_form(req.body.text())
      let email = normalize_email(required_form_value(form, "email", "email"))
      let name_key = required_form_value(form, "name_key", "name_key")
      let display_name = required_form_value(
        form, "display_name", "display name",
      )
      let role = optional_form_value(form, "role").unwrap_or("member")
      let bad_message = if !valid_email(email) {
        Some("invalid email")
      } else if !valid_name_key(name_key) {
        Some("invalid name_key")
      } else if !valid_team_invite_role(role) {
        Some("invalid role")
      } else {
        None
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
              can_manage~,
              Some(message),
            ),
            status=400,
          )
        }
        None => {
          let _ = invite_team_member(
            pool, actor, team, email, name_key, display_name, role,
          )
          res.send_void(
            status=303,
            headers=redirect_headers("/teams/\{team.name_key}"),
          )
        }
      }
    })
    ctx.post("/teams/:team/invitations/:invitation/revoke", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      let invitation_id = require_invitation_id(req)
      let _ = revoke_invitation(pool, actor, team.id, invitation_id)
      res.send_void(
        status=303,
        headers=redirect_headers("/teams/\{team.name_key}"),
      )
    })
    ctx.post("/teams/:team/invitations/:invitation/resend", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      let invitation_id = require_invitation_id(req)
      let _ = resend_invitation_email(pool, actor, team.id, invitation_id)
      res.send_void(
        status=303,
        headers=redirect_headers("/teams/\{team.name_key}"),
      )
    })
  })
}
