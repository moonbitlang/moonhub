///|
async fn ssh_import_available(
  config : @repository.RepoImportConfig?,
  owner : String,
) -> Bool {
  guard config is Some(config) else { return false }
  try {
    ignore(@repository.team_import_credentials(config, owner))
    true
  } catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => false
  }
}

///|
fn requested_team_repo(
  req : @moonback.Request,
  team : @identity.TeamSummary,
) -> String raise {
  let name = @web_context.required_param(req, "repo", "repository")
  @domain.parse_transport_repo("\{team.name_key}/\{name}.git").name
}

///|
async fn handle_repository_create(
  req : @moonback.Request,
  res : @moonback.Responder,
  pool : @database.Database,
  root : String,
  config : @repository.RepoImportConfig?,
  assets : Map[String, String],
  importing : Bool,
  addresses : @repository.SshAddressConfig,
) -> Unit {
  let actor = @web_context.require_current_user(req)
  let team = @web_context.require_owner_namespace(pool, req)
  @repository.require_repository_manager(pool, actor, team)
  let scope = "team-repositories:\{team.id}"
  let form = @web_context.protected_form(req, scope)
  let name = form.get("name").unwrap_or("").trim().to_owned()
  let visibility = form.get("visibility").unwrap_or("private")
  let source_url = if importing {
    form.get("source_url").unwrap_or("").trim().to_owned()
  } else {
    ""
  }
  let available = ssh_import_available(config, team.name_key)
  let repo = try {
    if importing {
      let source = @repository.resolve_repository_import_source(
        pool, actor, source_url, addresses,
      )
      guard available && config is Some(config) else {
        raise @domain.BadRequest(
          message="SSH imports are not configured for this namespace",
        )
      }
      @repository.authorize_import_source(
        @repository.team_import_credentials(config, team.name_key),
        source.transport,
      )
    }
    @repository.enqueue_repository(
      pool,
      root,
      actor,
      team,
      name,
      visibility,
      source_url,
      addresses~,
    )
  } catch {
    @domain.BadRequest(message~) => {
      res.send_html(
        render_repository_form(
          assets,
          actor,
          team,
          @web_context.request_form_token(req, scope),
          importing,
          available,
          name,
          visibility,
          source_url,
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
      location="/\{team.name_key}/-/repositories/\{repo.name}/status",
    ),
  )
}

///|
pub let repositories_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  let config = ctx.resolve(@web_context.config_repo_import)
  let addresses = ctx.require(@web_context.config_ssh_addresses)
  ctx.get("/:owner/-/repositories/new", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let team = @web_context.require_owner_namespace(pool, req)
    @repository.require_repository_manager(pool, actor, team)
    res.send_html(
      render_repository_form(
        assets,
        actor,
        team,
        @web_context.request_form_token(req, "team-repositories:\{team.id}"),
        false,
        ssh_import_available(config, team.name_key),
        "",
        "private",
        "",
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/:owner/-/repositories/import", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let team = @web_context.require_owner_namespace(pool, req)
    @repository.require_repository_manager(pool, actor, team)
    res.send_html(
      render_repository_form(
        assets,
        actor,
        team,
        @web_context.request_form_token(req, "team-repositories:\{team.id}"),
        true,
        ssh_import_available(config, team.name_key),
        "",
        "private",
        "",
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/-/repositories", async fn(req, res) {
    handle_repository_create(
      req, res, pool, root, config, assets, false, addresses,
    )
  })
  ctx.post("/:owner/-/repositories/import", async fn(req, res) {
    handle_repository_create(
      req, res, pool, root, config, assets, true, addresses,
    )
  })
  ctx.get("/:owner/-/repositories/:repo/status", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let team = @web_context.require_owner_namespace(pool, req)
    @identity.require_team_member_access(pool, actor, team)
    let job = @repository.require_repository_job(
      pool,
      team,
      requested_team_repo(req, team),
    )
    if job.status == "succeeded" {
      res.send_void(
        status=303,
        headers=@web_context.private_page_headers(
          location=@web_ui.repo_link(job.repo),
        ),
      )
    } else {
      res.send_html(
        render_repository_job(
          assets,
          actor,
          team,
          job,
          @web_context.request_form_token(req, "team-repositories:\{team.id}"),
          @identity.can_manage_team(pool, actor, team.id),
          false,
        ),
        headers=@web_context.private_page_headers(
          refresh=job.status == "pending" || job.status == "running",
        ),
      )
    }
  })
  ctx.post("/:owner/-/repositories/:repo/retry", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let team = @web_context.require_owner_namespace(pool, req)
    @repository.require_repository_manager(pool, actor, team)
    let _ = @web_context.protected_form(req, "team-repositories:\{team.id}")
    let name = requested_team_repo(req, team)
    @repository.retry_repository_job(pool, actor, team, name)
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location="/\{team.name_key}/-/repositories/\{name}/status",
      ),
    )
  })
  ctx.get("/:owner/-/repositories/:repo/discard", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let team = @web_context.require_owner_namespace(pool, req)
    @repository.require_repository_manager(pool, actor, team)
    let job = @repository.require_repository_job(
      pool,
      team,
      requested_team_repo(req, team),
    )
    guard job.status == "failed" else {
      raise @domain.NotFound(message="failed repository operation not found")
    }
    res.send_html(
      render_repository_job(
        assets,
        actor,
        team,
        job,
        @web_context.request_form_token(req, "team-repositories:\{team.id}"),
        true,
        true,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/-/repositories/:repo/discard", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let team = @web_context.require_owner_namespace(pool, req)
    @repository.require_repository_manager(pool, actor, team)
    let _ = @web_context.protected_form(req, "team-repositories:\{team.id}")
    @repository.discard_repository_job(
      pool,
      root,
      actor,
      team,
      requested_team_repo(req, team),
    )
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(location="/\{team.name_key}"),
    )
  })
})
