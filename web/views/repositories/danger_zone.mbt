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
  for action in ["visibility", "transfer", "delete"] {
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
          transfer_targets=if action == "transfer" {
            @repository.repository_transfer_targets(
              pool,
              actor,
              settings.scope.team_id,
            )
          } else {
            []
          },
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
      let confirmation = form.get("confirmation").unwrap_or("")
      let target_team = form.get("target_team_id").unwrap_or("")
      let location = try {
        let id = @web_context.positive_resource_number(
          form.get("repository_id").unwrap_or(""),
        )
        match action {
          "visibility" => {
            @repository.change_repository_visibility(
              pool,
              root,
              actor,
              repo,
              id,
              form.get("previous").unwrap_or(""),
              form.get("visibility").unwrap_or(""),
            )
            "\{@web_ui.repo_link(repo)}/settings/danger-zone"
          }
          "transfer" => {
            let target_team_id = @web_context.positive_resource_number(
              target_team,
            )
            let target = @repository.transfer_repository(
              pool, root, actor, repo, id, target_team_id, confirmation,
            )
            @web_ui.repo_link(target)
          }
          _ => {
            @repository.delete_repository(
              pool, root, actor, repo, id, confirmation,
            )
            "/\{repo.owner}"
          }
        }
      } catch {
        @domain.BadRequest(message~) | @gitops.Failure(message~) => {
          // Reload current state so a stale form offers a fresh confirmation.
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
              confirmation~,
              transfer_targets=if action == "transfer" {
                @repository.repository_transfer_targets(
                  pool,
                  actor,
                  current.scope.team_id,
                )
              } else {
                []
              },
              target_team~,
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
        headers=@web_context.private_page_headers(location~),
      )
    })
  }
})
