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
  ctx.use_(diff_dependencies_module)
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
  ctx.provide(
    @web_context.config_mirror,
    config
    .get_custom(@web_context.config_mirror)
    .unwrap_or(@repository.default_mirror_config),
  )
  if config.get_custom(@web_context.config_repo_import) is Some(import_config) {
    ctx.provide(@web_context.config_repo_import, import_config)
  }
  ctx.provide(@web_context.browser_access_key, {
    repositories: req => {
      @repository.visible_repositories(
        pool,
        root,
        @web_context.current_user_from_request(req),
      )
    },
    personal_owner: req => {
      match @web_context.current_user_from_request(req) {
        Some(actor) =>
          @identity.personal_namespace(pool, actor).map(team => team.name_key)
        None => None
      }
    },
    authorize: (req, repo) => {
      guard @repository.can_read_repository(
        pool,
        @web_context.current_user_from_request(req),
        repo,
      ) else {
        raise @domain.NotFound(message="repository not found or access denied")
      }
    },
    clone_url: repo => {
      @repository.effective_ssh_endpoint(pool, addresses).map(endpoint => {
        endpoint.clone_url(repo)
      })
    },
    manager: (req, repo) => {
      match @web_context.current_user_from_request(req) {
        Some(actor) =>
          match @identity.get_team_by_name_key(pool, repo.owner) {
            Some(team) => @identity.can_manage_team(pool, actor, team.id)
            None => false
          }
        None => false
      }
    },
  })
})

///|
let user_api_dependencies_module : @moonback.Module = Module(ctx => {
  ctx.use_(diff_dependencies_module)
  guard ctx.config().get_custom(@web_context.config_db_pool) is Some(pool) else {
    raise @domain.BadRequest(message="missing moonhub.db_pool")
  }
  ctx.provide(@web_context.config_db_pool, pool)
  ctx.use_(pipeline_dependencies_module)
  ctx.use_(webhook_dependencies_module)
})

///|
// Only this boundary reads deployment configuration; routes require the provider.
fn webhook_policy() -> @webhooks.Policy {
  @webhooks.Policy::new(
    allowed_origins=@config.env_value("MOONHUB_WEBHOOK_ALLOWED_ORIGINS")
      .map(value => {
        value.split(",").map(origin => origin.trim().to_owned()).collect()
      })
      .unwrap_or([]),
  )
}

///|
let webhook_dependencies_module : @moonback.Module = Module(ctx => {
  ctx.provide(
    @web_context.webhook_policy_key,
    ctx
    .config()
    .get_custom(@web_context.webhook_policy_key)
    .unwrap_or_else(webhook_policy),
  )
})

///|
let mcp_app_module : @moonback.Module = Module(ctx => {
  ctx.use_(user_api_dependencies_module)
  ctx.provide(
    @mcp.allowed_origins_key,
    @config.env_value("MOONHUB_MCP_ALLOWED_ORIGINS")
    .map(value => {
      value.split(",").map(origin => origin.trim().to_owned()).collect()
    })
    .unwrap_or([]),
  )
  ctx.use_(@mcp.mcp_module)
})

///|
let diff_dependencies_module : @moonback.Module = Module(ctx => {
  let executor = ctx
    .config()
    .get_custom(@web_context.diff_executor_key)
    .unwrap_or_else(() => diff_executor_from_env())
  ctx.provide(@web_context.diff_executor_key, executor)
  ctx.provide(
    @web_context.diff_enabled_key,
    ctx.config().get_custom(@web_context.diff_enabled_key).unwrap_or(false),
  )
})
