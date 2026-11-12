///|
pub async fn serve(config : Config) -> Unit {
  let diff_executor = diff_executor_from_env(observe=event => {
    println(event.stringify())
  })
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM])
  let diff_enabled = @config.env_value("MOONHUB_WEB_MOONDIFF").unwrap_or("true") !=
    "false"
  if diff_enabled {
    diff_executor.verify() catch {
      _ =>
        raise @domain.BadRequest(
          message="MoonDiff worker is unavailable or incompatible; check MOONHUB_DIFF_WORKER",
        )
    }
  }
  @async.with_task_group(group => {
    let pool = @database.new_db_pool(@database.db_config_from_env(), group)
    group.add_defer(() => pool.close())
    @database.initialize_db(pool)
    @attachments.start_cleanup_worker(pool, config.root, group)
    @identity.ensure_root_invitation(pool, config.root_user)
    @mail.start_mail_worker(pool, group)
    @webhooks.start_worker(pool, config.root, webhook_policy(), group)
    let import_config = @repository.repo_import_config_from_env()
    let mirror_config = @repository.mirror_config_from_env()
    @repository.start_mirror_worker(pool, config.root, mirror_config, group)
    let addresses = @repository.ssh_address_config_from_env()
    @repository.start_repository_worker(
      pool,
      config.root,
      import_config,
      group,
      addresses~,
    )
    @collaboration.start_merge_worker(pool, config.root, group)
    @collaboration.start_review_requests_worker(pool, config.root, group)
    let oidc = match @config.env_value("MOONHUB_OIDC_CONFIG") {
      Some(path) =>
        Some(
          @pipeline.OidcIssuer::load(
            path,
            node=@config.env_value("MOONHUB_OIDC_NODE").unwrap_or("node"),
          ),
        )
      None => None
    }
    let storage = match @config.env_value("MOONHUB_STORAGE_CONFIG") {
      Some(path) =>
        Some(
          @storage.Config::load(
            path,
            node=@config.env_value("MOONHUB_STORAGE_NODE").unwrap_or("node"),
            helper=@config.env_value("MOONHUB_S3_HELPER").unwrap_or(
              "storage/s3/bridge.mjs",
            ),
          ),
        )
      None => None
    }
    let coordinator = @pipeline.Coordinator::new(pool, oidc?, storage?)
    coordinator.start_lease_worker(group)
    group.spawn_bg(no_wait=true, () => {
      for ;; {
        coordinator.cleanup_artifacts(config.root) catch {
          _ => println("artifact cleanup failed; will retry")
        }
        @async.sleep(60000)
      }
    })
    @pipeline.start_push_worker(pool, config.root, group)
    @pipeline.start_merge_checks_worker(pool, config.root, group)
    let custom = [
      @moonback.Config::custom(@web_context.diff_executor_key, diff_executor),
      @moonback.Config::custom(@web_context.diff_enabled_key, diff_enabled),
      @moonback.Config::custom(
        @web_context.pipeline_coordinator_key, coordinator,
      ),
      @moonback.Config::custom(@web_context.config_root, config.root),
      @moonback.Config::custom(
        @web_context.config_assets_root,
        config.assets_root,
      ),
      @moonback.Config::custom(@web_context.config_db_pool, pool),
      @moonback.Config::custom(@web_context.config_mirror, mirror_config),
      @moonback.Config::custom(@web_context.config_ssh_addresses, addresses),
    ]
    if import_config is Some(config) {
      custom.push(
        @moonback.Config::custom(@web_context.config_repo_import, config),
      )
    }
    let app = @moonback.App(app_module, config=Config(custom~))
    defer app.close()
    let listener = @moonback.listen(host=config.host, port=config.port)
    println(
      "moonhub serving \{config.root} at http://\{config.host}:\{config.port}",
    )
    app.serve(listener)
  })
}
