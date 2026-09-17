///|
/// Resolves the namespace named by the request's owner segment. A namespace is
/// the team row behind a repository owner, whether it is an organization team
/// or the personal namespace of a user.
fn require_owner_namespace(
  pool : Database,
  req : @moonback.Request,
) -> TeamSummary raise {
  let owner = req.required_param("owner", "namespace")
  guard valid_repo_owner(owner) else {
    raise NotFound(message="namespace not found")
  }
  match get_team_by_name_key(pool, owner) {
    Some(team) => team
    None => raise NotFound(message="namespace not found")
  }
}

///|
/// Accepts any member of the namespace, or a site administrator.
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
/// Member and invitation views describe an organization team. A user's personal
/// namespace has no such views, so it is never a team here.
fn require_organization_namespace(
  pool : Database,
  req : @moonback.Request,
) -> TeamSummary raise {
  let team = require_owner_namespace(pool, req)
  guard team.kind == "org" else { raise NotFound(message="team not found") }
  team
}

///|
fn valid_namespace_tab(tab : String) -> Bool {
  ["repositories", "members", "invitations"].contains(tab)
}

///|
fn namespaces_module(assets : Map[String, String]) -> @moonback.Module {
  Module(ctx => {
    let pool = db_pool(ctx)
    ctx.get("/:owner", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_owner_namespace(pool, req)
      let can_manage = can_manage_team(pool, actor, team.id)
      if team.kind == "personal" {
        res.send_html(
          render_namespace(
            assets,
            actor,
            team,
            namespace_repositories(pool, actor, team, can_manage),
            can_manage,
          ),
          headers=private_page_headers(),
        )
        return
      }
      // Member and invitation views stay private to the team.
      require_team_member_access(pool, actor, team)
      let members = list_team_members(pool, team)
      let invitations = list_invitations(pool, team)
      let active_tab = req.query().get("tab").unwrap_or("repositories")
      guard valid_namespace_tab(active_tab) else {
        raise BadRequest(message="invalid team view")
      }
      res.send_html(
        render_team_detail(
          assets,
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
  })
}
