///|
pub let mirrors_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  let assets = ctx.require(@web_context.asset_paths_key)
  let mirror_config = ctx.require(@web_context.config_mirror)
  ctx.get("/:owner/:repo/settings/mirrors", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let scope = @repository.require_mirror_manager(pool, actor, repo)
    res.send_html(
      render_mirrors(
        assets,
        actor,
        repo,
        @repository.push_mirrors(pool, actor, repo),
        @web_context.request_form_token(req, "mirrors:\{scope.id}"),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  for editing in [false, true] {
    let route = if editing {
      "/:owner/:repo/settings/mirrors/:mirror"
    } else {
      "/:owner/:repo/settings/mirrors/new"
    }
    ctx.get(route, async fn(req, res) {
      let actor = @web_context.require_current_user(req)
      let repo = @web_context.repo_param(req)
      let scope = @repository.require_mirror_manager(pool, actor, repo)
      let mirror = if editing {
        find_mirror(
          @repository.push_mirrors(pool, actor, repo),
          @web_context.positive_resource_number(
            @web_context.required_param(req, "mirror", "mirror"),
          ),
        )
      } else {
        new_mirror
      }
      let history = if editing {
        @repository.mirror_history(pool, actor, repo, mirror.id)
      } else {
        []
      }
      res.send_html(
        render_mirror_form(
          assets,
          actor,
          repo,
          mirror,
          history,
          @web_context.request_form_token(req, "mirrors:\{scope.id}"),
          None,
        ),
        headers=@web_context.private_page_headers(),
      )
    })
    ctx.post(if editing { route } else { "/:owner/:repo/settings/mirrors" }, async fn(
      req,
      res,
    ) {
      let actor = @web_context.require_current_user(req)
      let repo = @web_context.repo_param(req)
      let scope = @repository.require_mirror_manager(pool, actor, repo)
      let form = @web_context.protected_form(req, "mirrors:\{scope.id}")
      let id = if editing {
        @web_context.positive_resource_number(
          @web_context.required_param(req, "mirror", "mirror"),
        )
      } else {
        0L
      }
      let version = if editing {
        @web_context.positive_resource_number(form.get("version").unwrap_or(""))
      } else {
        0L
      }
      let persisted = if editing {
        Some(find_mirror(@repository.push_mirrors(pool, actor, repo), id))
      } else {
        None
      }
      let current = persisted.unwrap_or(new_mirror)
      let history = if editing {
        @repository.mirror_history(pool, actor, repo, id)
      } else {
        []
      }
      let mirror : @repository.PushMirror = {
        ..current,
        id,
        version,
        url: form.get("url").unwrap_or(""),
        active: form.get("active") == Some("1"),
        force_push: form.get("force_push") == Some("1"),
        prune: form.get("prune") == Some("1"),
      }
      let saved = @repository.save_push_mirror(
        pool,
        root,
        actor,
        repo,
        id,
        version,
        mirror.url,
        mirror.active,
        mirror.force_push,
        mirror.prune,
      ) catch {
        @domain.BadRequest(message~) => {
          res.send_html(
            render_mirror_form(
              assets,
              actor,
              repo,
              mirror,
              history,
              @web_context.request_form_token(req, "mirrors:\{scope.id}"),
              Some(message),
              destination_saved=mirror.url == current.url,
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
          location="\{@web_ui.repo_link(repo)}/settings/mirrors/\{saved}",
        ),
      )
    })
  }
  for
    action in [
      "sync", "delete", "rotate-key", "initialize-host", "confirm-host",
    ] {
    ctx.post("/:owner/:repo/settings/mirrors/:mirror/" + action, async fn(
      req,
      res,
    ) {
      let actor = @web_context.require_current_user(req)
      let repo = @web_context.repo_param(req)
      let scope = @repository.require_mirror_manager(pool, actor, repo)
      let form = @web_context.protected_form(req, "mirrors:\{scope.id}")
      let id = @web_context.positive_resource_number(
        @web_context.required_param(req, "mirror", "mirror"),
      )
      let version = @web_context.positive_resource_number(
        form.get("version").unwrap_or(""),
      )
      try {
        if action == "initialize-host" {
          @repository.initialize_mirror_host(
            pool, root, actor, repo, id, version, mirror_config,
          )
        } else if action == "confirm-host" {
          @repository.confirm_mirror_host(
            pool,
            root,
            actor,
            repo,
            id,
            version,
            form.get("challenge").unwrap_or(""),
          )
        } else if action == "rotate-key" {
          @repository.rotate_mirror_key(pool, root, actor, repo, id, version)
        } else {
          @repository.push_mirror_action(
            pool, root, actor, repo, id, version, action,
          )
        }
      } catch {
        @domain.BadRequest(message~) => {
          let mirror = find_mirror(
            @repository.push_mirrors(pool, actor, repo),
            id,
          )
          res.send_html(
            render_mirror_form(
              assets,
              actor,
              repo,
              mirror,
              @repository.mirror_history(pool, actor, repo, id),
              @web_context.request_form_token(req, "mirrors:\{scope.id}"),
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
          location="\{@web_ui.repo_link(repo)}/settings/mirrors" +
            (if action == "rotate-key" ||
              action == "initialize-host" ||
              action == "confirm-host" {
              "/" + id.to_string()
            } else {
              ""
            }),
        ),
      )
    })
  }
})

///|
let new_mirror : @repository.PushMirror = {
  id: 0L,
  url: "",
  public_key: "",
  host_keys: "",
  host_check: None,
  active: false,
  force_push: false,
  prune: false,
  version: 0L,
  status: "pending",
  attempts: 0L,
  error: "",
  last_success_at: None,
  next_attempt_at: "",
}

///|
fn find_mirror(
  mirrors : Array[@repository.PushMirror],
  id : Int64,
) -> @repository.PushMirror raise {
  guard mirrors.iter().find_first(mirror => mirror.id == id) is Some(mirror) else {
    raise @domain.NotFound(message="mirror not found")
  }
  mirror
}
