///|
let pipeline_dependencies_module : @moonback.Module = Module(ctx => {
  let config = ctx.config()
  guard config.get_custom(@web_context.config_db_pool) is Some(pool) else {
    raise @domain.BadRequest(message="missing moonhub.db_pool")
  }
  let coordinator = config
    .get_custom(@web_context.pipeline_coordinator_key)
    .unwrap_or_else(() => @pipeline.Coordinator::new(pool))
  ctx.provide(@web_context.pipeline_coordinator_key, coordinator)
  if ctx.resolve(@web_context.config_root) is None {
    if config.get_custom(@web_context.config_root) is Some(root) {
      ctx.provide(@web_context.config_root, root)
    }
  }
})

///|
// Configuration enters at the application boundary. Feature modules consume
// app-scoped dependencies and never reload the manifest or inspect bootstrap config.
pub let browser_resources_module : @moonback.Module = Module(ctx => {
  let config = ctx.config()
  guard config.get_custom(@web_context.config_root) is Some(root) else {
    raise @domain.BadRequest(message="missing moonhub.root")
  }
  guard config.get_custom(@web_context.config_assets_root) is Some(assets_root) else {
    raise @domain.BadRequest(message="missing moonhub.assets_root")
  }
  ctx.provide(@web_context.config_root, root)
  ctx.provide(
    @web_context.asset_paths_key,
    @web_assets.load_entry_to_asset_path_map(assets_root),
  )
})

///|
let services_module : @moonback.Module = Module(ctx => {
  let config = ctx.config()
  guard config.get_custom(@web_context.config_db_pool) is Some(pool) else {
    raise @domain.BadRequest(message="missing moonhub.db_pool")
  }
  let root = ctx.require(@web_context.config_root)
  let addresses = config
    .get_custom(@web_context.config_ssh_addresses)
    .unwrap_or(@repository.no_ssh_address_config)
  ctx.provide(@web_context.config_db_pool, pool)
  ctx.provide(@web_context.config_ssh_addresses, addresses)
  if config.get_custom(@web_context.config_repo_import) is Some(import_config) {
    ctx.provide(@web_context.config_repo_import, import_config)
  }
  ctx.provide(@web_context.browser_access_key, {
    repositories: req => {
      @repository.visible_repositories(
        pool,
        root,
        @web_context.require_current_user(req),
      )
    },
    personal_owner: req => {
      @identity.personal_namespace(pool, @web_context.require_current_user(req)).map(team => {
          team.name_key
        },
      )
    },
    authorize: (req, repo) => {
      @repository.authorize_repository(
        pool,
        @web_context.require_current_user(req),
        repo,
        Read,
      )
    },
    clone_url: repo => {
      @repository.effective_ssh_endpoint(pool, addresses).map(endpoint => {
        endpoint.clone_url(repo)
      })
    },
    manager: (req, repo) => {
      match @identity.get_team_by_name_key(pool, repo.owner) {
        Some(team) =>
          @identity.can_manage_team(
            pool,
            @web_context.require_current_user(req),
            team.id,
          )
        None => false
      }
    },
  })
})
