///|
pub let app_module : @moonback.Module = Module(ctx => {
  let config = ctx.config()
  ctx.mount("/\{@domain.PUBLIC_ASSETS_OWNER}", App(assets_module, config~))
  ctx.mount("/-/runner-api/v1", App(runner_app_module, config~))
  ctx.mount("/", App(app_main_module, config~))
})

///|
let runner_app_module : @moonback.Module = Module(ctx => {
  ctx.use_(pipeline_dependencies_module)
  ctx.use_(@pipeline_views.runner_api_module)
})

///|
let app_main_module : @moonback.Module = Module(ctx => {
  ctx.use_(browser_resources_module)
  ctx.use_(services_module)
  ctx.use_(pipeline_dependencies_module)
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.add_middleware(@web_context.app_error_middleware(assets))
  ctx.add_middleware(@web_context.auth_middleware(pool))
  ctx.add_middleware(@web_context.require_login_middleware())
  ctx.use_(@auth_views.auth_module)
  ctx.use_(@account_views.profile_module)
  ctx.use_(@account_views.ssh_keys_module)
  ctx.use_(@settings_views.site_settings_module)
  ctx.use_(@repository_views.index_module)
  ctx.use_(@namespace_views.teams_module)
  ctx.use_(@namespace_views.namespaces_module)
  ctx.use_(@repository_views.repositories_module)
  ctx.use_(@repository_views.deploy_keys_module)
  ctx.use_(@merge_request_views.merge_requests_module)
  ctx.use_(@issue_views.issues_module)
  ctx.use_(@pipeline_views.pipeline_pages_module)
  ctx.use_(@repository_views.repo_browser_module)
})

///|
pub let assets_module : @moonback.Module = Module(ctx => {
  guard ctx.config().get_custom(@web_context.config_assets_root) is Some(root) else {
    raise @domain.BadRequest(message="missing moonhub.assets_root")
  }
  ctx.add_middleware(@web_assets.static_assets(root~))
})
