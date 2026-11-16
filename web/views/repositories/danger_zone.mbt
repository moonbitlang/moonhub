///|
pub let danger_zone_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  ctx.get("/:owner/:repo/settings/danger-zone", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let settings = @repository.repository_settings(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    res.send_html(
      render_danger_zone(assets, actor, settings, "", ""),
      headers=@web_context.private_page_headers(),
    )
  })
  for action in ["visibility", "delete"] {
    let route = "/:owner/:repo/settings/danger-zone/" + action
    ctx.get(route, async fn(req, res) {
      let actor = @web_context.require_current_user(req)
      let settings = @repository.repository_settings(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      res.send_html(
        render_danger_zone(
          assets,
          actor,
          settings,
          action,
          @web_context.request_form_token(
            req,
            "repository-\{action}:\{settings.scope.id}",
          ),
        ),
        headers=@web_context.private_page_headers(),
      )
    })
    ctx.post(route, async fn(req, res) {
      let actor = @web_context.require_current_user(req)
      let repo = @web_context.repo_param(req)
      let settings = @repository.repository_settings(pool, actor, repo)
      let token_scope = "repository-\{action}:\{settings.scope.id}"
      let form = @web_context.protected_form(req, token_scope)
      try {
        let id = @web_context.positive_resource_number(
          form.get("repository_id").unwrap_or(""),
        )
        if action == "visibility" {
          @repository.change_repository_visibility(
            pool,
            root,
            actor,
            repo,
            id,
            form.get("previous").unwrap_or(""),
            form.get("visibility").unwrap_or(""),
          )
        } else {
          @repository.delete_repository(
            pool,
            root,
            actor,
            repo,
            id,
            form.get("confirmation").unwrap_or(""),
          )
        }
      } catch {
        @domain.BadRequest(message~) | @gitops.Failure(message~) => {
          // Reload current state so an expired visibility form offers a new confirmation.
          let current = @repository.repository_settings(pool, actor, repo)
          res.send_html(
            render_danger_zone(
              assets,
              actor,
              current,
              action,
              @web_context.request_form_token(
                req,
                "repository-\{action}:\{current.scope.id}",
              ),
              confirmation=form.get("confirmation").unwrap_or(""),
              error=Some(message),
            ),
            status=400,
            headers=@web_context.private_page_headers(),
          )
          return
        }
        err => raise err
      }
      res.send_void(
        status=303,
        headers=@web_context.private_page_headers(
          location=if action == "delete" {
            "/\{repo.owner}"
          } else {
            "\{@web_ui.repo_link(repo)}/settings/danger-zone"
          },
        ),
      )
    })
  }
})
