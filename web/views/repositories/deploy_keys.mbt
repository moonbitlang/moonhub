///|
fn deploy_key_write_access(form : Map[String, String]) -> Bool raise {
  match form.get("write_access") {
    None => false
    Some("1") => true
    _ => raise @domain.BadRequest(message="invalid deploy key access mode")
  }
}

///|
pub let deploy_keys_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.get("/:owner/:repo/settings/deploy-keys", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    res.send_html(
      render_deploy_keys(
        assets,
        actor,
        repo,
        @ssh.repository_deploy_keys(pool, actor, repo),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/:owner/:repo/settings/deploy-keys/new", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let scope = @ssh.require_deploy_key_manager(pool, actor, repo)
    res.send_html(
      render_new_deploy_key(
        assets,
        actor,
        repo,
        @web_context.request_form_token(req, "deploy-keys:\{scope.id}"),
        "",
        "",
        false,
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/settings/deploy-keys", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let scope = @ssh.require_deploy_key_manager(pool, actor, repo)
    let token_scope = "deploy-keys:\{scope.id}"
    let form = @web_context.protected_form(req, token_scope)
    let title = form.get("title").unwrap_or("").trim().to_owned()
    let public_key = form.get("public_key").unwrap_or("")
    try {
      guard !public_key.contains("PRIVATE KEY") else {
        raise @domain.BadRequest(
          message="enter an Ed25519 public key, not a private key",
        )
      }
      ignore(
        @ssh.add_repository_deploy_key(
          pool,
          actor,
          repo,
          title,
          @ssh.parse_ssh_public_key(public_key),
          write_access=deploy_key_write_access(form),
        ),
      )
    } catch {
      @domain.BadRequest(message~) => {
        res.send_html(
          render_new_deploy_key(
            assets,
            actor,
            repo,
            @web_context.request_form_token(req, token_scope),
            title,
            if public_key.contains("PRIVATE KEY") {
              ""
            } else {
              public_key
            },
            form.get("write_access") == Some("1"),
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
      headers=@web_context.private_page_headers(
        location="\{@web_ui.repo_link(repo)}/settings/deploy-keys",
      ),
    )
  })
  for action in ["access", "revoke"] {
    ctx.get("/:owner/:repo/settings/deploy-keys/:key/" + action, async fn(
      req,
      res,
    ) {
      let actor = @web_context.require_current_user(req)
      let repo = @web_context.repo_param(req)
      let scope = @ssh.require_deploy_key_manager(pool, actor, repo)
      let id = @web_context.positive_resource_number(
        @web_context.required_param(req, "key", "deploy key"),
      )
      let keys = @ssh.repository_deploy_keys(pool, actor, repo)
      let key = keys
        .iter()
        .find_first(key => key.id == id && key.revoked_at is None)
      guard key is Some(key) else {
        raise @domain.NotFound(message="active deploy key not found")
      }
      res.send_html(
        render_deploy_key_action(
          assets,
          actor,
          repo,
          @web_context.request_form_token(req, "deploy-keys:\{scope.id}"),
          key,
          action,
        ),
        headers=@web_context.private_page_headers(),
      )
    })
    ctx.post("/:owner/:repo/settings/deploy-keys/:key/" + action, async fn(
      req,
      res,
    ) {
      let actor = @web_context.require_current_user(req)
      let repo = @web_context.repo_param(req)
      let scope = @ssh.require_deploy_key_manager(pool, actor, repo)
      let form = @web_context.protected_form(req, "deploy-keys:\{scope.id}")
      let id = @web_context.positive_resource_number(
        @web_context.required_param(req, "key", "deploy key"),
      )
      if action == "revoke" {
        @ssh.revoke_repository_deploy_key(pool, actor, repo, id)
      } else {
        @ssh.set_repository_deploy_key_access(
          pool,
          actor,
          repo,
          id,
          deploy_key_write_access(form),
        )
      }
      res.send_void(
        status=303,
        headers=@web_context.private_page_headers(
          location="\{@web_ui.repo_link(repo)}/settings/deploy-keys",
        ),
      )
    })
  }
})
