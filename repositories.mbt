///|
async fn ssh_import_available(
  config : RepoImportConfig?,
  owner : String,
) -> Bool {
  guard config is Some(config) else { return false }
  try {
    ignore(team_import_credentials(config, owner))
    true
  } catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => false
  }
}

///|
fn requested_team_repo(
  req : @moonback.Request,
  team : TeamSummary,
) -> String raise {
  let name = req.required_param("repo", "repository")
  parse_transport_repo("\{team.name_key}/\{name}.git").name
}

///|
async fn handle_repository_create(
  req : @moonback.Request,
  res : @moonback.Responder,
  pool : Database,
  root : String,
  config : RepoImportConfig?,
  assets : Map[String, String],
  importing : Bool,
  addresses : SshAddressConfig,
) -> Unit {
  let actor = require_current_user(req)
  let team = require_team_by_request(pool, req)
  require_repository_manager(pool, actor, team)
  let scope = "team-repositories:\{team.id}"
  let form = protected_form(req, scope)
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
      let source = resolve_repository_import_source(
        pool, actor, source_url, addresses,
      )
      guard available && config is Some(config) else {
        raise BadRequest(message="SSH imports are not configured for this team")
      }
      authorize_import_source(
        team_import_credentials(config, team.name_key),
        source.transport,
      )
    }
    enqueue_repository(
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
    BadRequest(message~) => {
      res.send_html(
        render_repository_form(
          assets,
          actor,
          team,
          request_form_token(req, scope),
          importing,
          available,
          name,
          visibility,
          source_url,
          Some(message),
        ),
        status=400,
        headers=private_page_headers(),
      )
      return
    }
    err => raise err
  }
  res.send_void(
    status=303,
    headers=private_page_headers(
      location="/teams/\{team.name_key}/repositories/\{repo.name}/status",
    ),
  )
}

///|
fn repositories_module(assets : Map[String, String]) -> @moonback.Module {
  Module(ctx => {
    let pool = db_pool(ctx)
    let root = repo_root(ctx)
    let config = ctx.config().get_custom(config_repo_import)
    let addresses = ctx
      .config()
      .get_custom(config_ssh_addresses)
      .unwrap_or(no_ssh_address_config)
    ctx.get("/teams/:team/repositories/new", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      require_repository_manager(pool, actor, team)
      res.send_html(
        render_repository_form(
          assets,
          actor,
          team,
          request_form_token(req, "team-repositories:\{team.id}"),
          false,
          ssh_import_available(config, team.name_key),
          "",
          "private",
          "",
          None,
        ),
        headers=private_page_headers(),
      )
    })
    ctx.get("/teams/:team/repositories/import", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      require_repository_manager(pool, actor, team)
      res.send_html(
        render_repository_form(
          assets,
          actor,
          team,
          request_form_token(req, "team-repositories:\{team.id}"),
          true,
          ssh_import_available(config, team.name_key),
          "",
          "private",
          "",
          None,
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/teams/:team/repositories", async fn(req, res) {
      handle_repository_create(
        req, res, pool, root, config, assets, false, addresses,
      )
    })
    ctx.post("/teams/:team/repositories/import", async fn(req, res) {
      handle_repository_create(
        req, res, pool, root, config, assets, true, addresses,
      )
    })
    ctx.get("/teams/:team/repositories/:repo/status", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      require_team_member_access(pool, actor, team)
      let job = require_repository_job(
        pool,
        team,
        requested_team_repo(req, team),
      )
      if job.status == "succeeded" {
        res.send_void(
          status=303,
          headers=private_page_headers(location=repo_link(job.repo)),
        )
      } else {
        res.send_html(
          render_repository_job(
            assets,
            actor,
            team,
            job,
            request_form_token(req, "team-repositories:\{team.id}"),
            can_manage_team(pool, actor, team.id),
            false,
          ),
          headers=private_page_headers(
            refresh=job.status == "pending" || job.status == "running",
          ),
        )
      }
    })
    ctx.post("/teams/:team/repositories/:repo/retry", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      require_repository_manager(pool, actor, team)
      let _ = protected_form(req, "team-repositories:\{team.id}")
      let name = requested_team_repo(req, team)
      retry_repository_job(pool, actor, team, name)
      res.send_void(
        status=303,
        headers=private_page_headers(
          location="/teams/\{team.name_key}/repositories/\{name}/status",
        ),
      )
    })
    ctx.get("/teams/:team/repositories/:repo/discard", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      require_repository_manager(pool, actor, team)
      let job = require_repository_job(
        pool,
        team,
        requested_team_repo(req, team),
      )
      guard job.status == "failed" else {
        raise NotFound(message="failed repository operation not found")
      }
      res.send_html(
        render_repository_job(
          assets,
          actor,
          team,
          job,
          request_form_token(req, "team-repositories:\{team.id}"),
          true,
          true,
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/teams/:team/repositories/:repo/discard", async fn(req, res) {
      let actor = require_current_user(req)
      let team = require_team_by_request(pool, req)
      require_repository_manager(pool, actor, team)
      let _ = protected_form(req, "team-repositories:\{team.id}")
      discard_repository_job(
        pool,
        root,
        actor,
        team,
        requested_team_repo(req, team),
      )
      res.send_void(
        status=303,
        headers=private_page_headers(location="/teams/\{team.name_key}"),
      )
    })
  })
}
