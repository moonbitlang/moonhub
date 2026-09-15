///|
async fn serve(config : Config) -> Unit {
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM])
  @async.with_task_group(group => {
    let pool = new_db_pool(db_config_from_env(), group)
    group.add_defer(() => pool.close())
    initialize_db(pool)
    ensure_root_invitation(pool, config.root_user)
    start_mail_worker(pool, group)
    let import_config = repo_import_config_from_env()
    let addresses = ssh_address_config_from_env()
    start_repository_worker(pool, config.root, import_config, group, addresses~)
    start_merge_worker(pool, config.root, group)
    let custom = [
      @moonback.Config::custom(config_root, config.root),
      @moonback.Config::custom(config_assets_root, config.assets_root),
      @moonback.Config::custom(config_db_pool, pool),
      @moonback.Config::custom(config_ssh_addresses, addresses),
    ]
    if import_config is Some(config) {
      custom.push(@moonback.Config::custom(config_repo_import, config))
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
