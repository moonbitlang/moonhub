///|
pub let repository_settings_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  let assets = ctx.require(@web_context.asset_paths_key)
  ctx.get("/:owner/:repo/settings", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.require_repository_admin(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    res.send_html(
      render_repository_settings(
        assets,
        actor,
        scope,
        @web_context.request_form_token(req, "delete-repository:\{scope.id}"),
        "",
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/settings/delete", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let scope = @repository.require_repository_admin(pool, actor, repo)
    // The current immutable ID determines the CSRF scope. An old form cannot
    // obtain a valid token for a repository recreated at the same URL.
    let form = @web_context.protected_form(req, "delete-repository:\{scope.id}")
    let confirmation = form.get("confirmation").unwrap_or("")
    try {
      let id = @web_context.positive_resource_number(
        form.get("repository_id").unwrap_or(""),
      )
      @repository.delete_repository(pool, root, actor, repo, id, confirmation)
    } catch {
      @domain.BadRequest(message~) => {
        res.send_html(
          render_repository_settings(
            assets,
            actor,
            scope,
            @web_context.request_form_token(
              req,
              "delete-repository:\{scope.id}",
            ),
            confirmation,
            Some(message),
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
      headers=@web_context.private_page_headers(location="/\{repo.owner}"),
    )
  })
})
