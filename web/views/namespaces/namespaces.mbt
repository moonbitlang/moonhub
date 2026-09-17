///|
fn valid_namespace_tab(tab : String) -> Bool {
  ["repositories", "members", "invitations"].contains(tab)
}

///|
pub let namespaces_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.get("/:owner", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let team = @web_context.require_owner_namespace(pool, req)
    let can_manage = @identity.can_manage_team(pool, actor, team.id)
    if team.kind == "personal" {
      res.send_html(
        render_namespace(
          assets,
          actor,
          team,
          @repository.namespace_repositories(pool, actor, team, can_manage),
          can_manage,
        ),
        headers=@web_context.private_page_headers(),
      )
      return
    }
    // Member and invitation views stay private to the team.
    @identity.require_team_member_access(pool, actor, team)
    let members = @identity.list_team_members(pool, team)
    let invitations = @identity.list_invitations(pool, team)
    let active_tab = req.query().get("tab").unwrap_or("repositories")
    guard valid_namespace_tab(active_tab) else {
      raise @domain.BadRequest(message="invalid team view")
    }
    res.send_html(
      render_team_detail(
        assets,
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
      headers=@web_context.private_page_headers(),
    )
  })
})
