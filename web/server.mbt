///|
pub async fn serve(config : Config) -> Unit {
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM])
  @async.with_task_group(group => {
    let pool = @database.new_db_pool(@database.db_config_from_env(), group)
    group.add_defer(() => pool.close())
    @database.initialize_db(pool)
    @attachments.start_cleanup_worker(pool, config.root, group)
    @identity.ensure_root_invitation(pool, config.root_user)
    @mail.start_mail_worker(pool, group)
    @webhooks.start_worker(pool, config.root, webhook_policy(), group)
    let import_config = @repository.repo_import_config_from_env()
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
    let coordinator = @pipeline.Coordinator::new(pool)
    coordinator.start_lease_worker(group)
    @pipeline.start_push_worker(pool, config.root, group)
    @pipeline.start_merge_checks_worker(pool, config.root, group)
    let custom = [
      @moonback.Config::custom(
        @web_context.pipeline_coordinator_key, coordinator,
      ),
      @moonback.Config::custom(@web_context.config_root, config.root),
      @moonback.Config::custom(
        @web_context.config_assets_root,
        config.assets_root,
      ),
      @moonback.Config::custom(@web_context.config_db_pool, pool),
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
