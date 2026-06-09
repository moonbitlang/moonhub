///|
async test "initializes app module" {
  let app = @moonback.App(
    app_module,
    config=Config(custom=[
      @moonback.Config::custom(config_root, "testdata/repos"),
    ]),
  )
  defer app.close()
}

///|
async test "serves repository paths from route params" {
  let app = @moonback.App(
    app_module,
    config=Config(custom=[
      @moonback.Config::custom(config_root, "testdata/repos"),
    ]),
  )
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let (response, body) = @http.get(
      "http://127.0.0.1:\{port}/alice/demo/blob/master/src/main.mbt",
    )
    assert_eq(response.code, 200)
    assert_true(body.text().contains("println(&quot;hi&quot;)"))
  })
}
