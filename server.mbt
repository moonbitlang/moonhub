///|
async fn serve(config : Config) -> Unit {
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM])
  let app = @moonback.App(
    app_module,
    config=Config(custom=[@moonback.Config::custom(config_root, config.root)]),
  )
  let listener = @moonback.listen(host=config.host, port=config.port)
  println(
    "moonhub serving \{config.root} at http://\{config.host}:\{config.port}",
  )
  app.serve(listener)
}
