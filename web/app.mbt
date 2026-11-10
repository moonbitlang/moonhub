///|
pub let app_module : @moonback.Module = Module(ctx => {
  let config = ctx.config()
  ctx.use_(pipeline_dependencies_module)
  ctx.use_(@pipeline_views.oidc_module)
  ctx.mount("/\{@domain.PUBLIC_ASSETS_OWNER}", App(assets_module, config~))
  ctx.mount("/-/api/v1", App(user_api_module, config~))
  ctx.mount("/-/mcp", App(mcp_app_module, config~))
  ctx.mount("/-/runner-api/v1", App(runner_app_module, config~))
  ctx.mount(
    "/twirp/github.actions.results.api.v1.ArtifactService",
    App(artifact_rpc_app_module, config~),
  )
  ctx.mount("/-/artifact-blobs", App(artifact_blob_app_module, config~))
  ctx.mount(
    "/twirp/github.actions.results.api.v1.CacheService",
    App(cache_rpc_app_module, config~),
  )
  ctx.mount("/", App(app_main_module, config~))
})

///|
let runner_app_module : @moonback.Module = Module(ctx => {
  ctx.use_(pipeline_dependencies_module)
  ctx.use_(@pipeline_views.runner_api_module)
})

///|
let artifact_rpc_app_module : @moonback.Module = Module(ctx => {
  ctx.use_(pipeline_dependencies_module)
  ctx.use_(@pipeline_views.artifact_rpc_module)
})

///|
let artifact_blob_app_module : @moonback.Module = Module(ctx => {
  ctx.use_(pipeline_dependencies_module)
  ctx.use_(@pipeline_views.artifact_blob_module)
})

///|
let app_main_module : @moonback.Module = Module(ctx => {
  ctx.use_(browser_resources_module)
  ctx.use_(services_module)
  ctx.use_(webhook_dependencies_module)
  ctx.use_(pipeline_dependencies_module)
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.add_middleware(@web_context.app_error_middleware(assets))
  ctx.add_middleware(@web_context.auth_middleware(pool))
  ctx.add_middleware(@web_context.require_login_middleware())
  ctx.use_(@auth_views.auth_module)
  ctx.use_(@notification_views.notifications_module)
  ctx.use_(@account_views.tokens_module)
  ctx.use_(@account_views.profile_module)
  ctx.use_(@account_views.ssh_keys_module)
  ctx.use_(@settings_views.site_settings_module)
  ctx.use_(@repository_views.index_module)
  ctx.use_(@namespace_views.teams_module)
  ctx.use_(@namespace_views.namespaces_module)
  ctx.use_(@repository_views.repositories_module)
  ctx.use_(@repository_views.deploy_keys_module)
  ctx.use_(@repository_views.webhooks_module)
  ctx.use_(@repository_views.mirrors_module)
  ctx.use_(@merge_request_views.merge_requests_module)
  ctx.use_(@issue_views.issues_module)
  ctx.use_(@attachment_views.attachments_module)
  ctx.use_(@pipeline_views.pipeline_pages_module)
  ctx.use_(@pipeline_views.repository_secrets_module)
  ctx.use_(@pipeline_views.repository_variables_module)
  ctx.use_(@repository_views.repo_browser_module)
})

///|
pub let assets_module : @moonback.Module = Module(ctx => {
  guard ctx.config().get_custom(@web_context.config_assets_root) is Some(root) else {
    raise @domain.BadRequest(message="missing moonhub.assets_root")
  }
  ctx.add_middleware(@web_assets.static_assets(root~))
})

///|
let user_api_module : @moonback.Module = Module(ctx => {
  ctx.use_(user_api_dependencies_module)
  ctx.use_(@user_api.api_module)
  ctx.use_(@user_api.webhooks_api_module)
})

///|
let cache_rpc_app_module : @moonback.Module = Module(ctx => {
  ctx.use_(pipeline_dependencies_module)
  ctx.use_(@pipeline_views.cache_rpc_module)
})
