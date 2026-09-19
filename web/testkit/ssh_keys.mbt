///|
pub async fn with_ssh_settings_app(
  f : async (Int, @database.Database, @http.Cookie, @http.Cookie, @http.Cookie) -> Unit,
  addresses? : @repository.SshAddressConfig = @repository.no_ssh_address_config,
  repo_root? : String = test_repo_root,
) -> Unit {
  @test_support.with_ssh_test_db(pool => {
    let cookies = pool.with_client(client => {
      client.with_transaction(tx => {
        [1L, 2L, 3L].map(id => {
          @web_context.session_cookie(@identity.create_session_token(tx, id))
        })
      })
    })
    let app = @moonback.App(
      @web.app_module,
      config=@moonback.Config(custom=[
        @moonback.Config::custom(@web_context.config_root, repo_root),
        @moonback.Config::custom(
          @web_context.config_assets_root, test_assets_root,
        ),
        @moonback.Config::custom(@web_context.config_db_pool, pool),
        @moonback.Config::custom(@web_context.config_ssh_addresses, addresses),
      ]),
    )
    defer app.close()
    @async.with_task_group(group => {
      let listener = @moonback.listen(port=0)
      let task = group.spawn(() => app.serve(listener))
      defer task.cancel()
      f(listener.addr.port(), pool, cookies[0], cookies[1], cookies[2])
    })
  })
}

///|
pub async fn settings_form_token(port : Int, cookie : @http.Cookie) -> String {
  let (response, body) = http_get_path_with_cookie(
    port, "/-/settings/ssh-keys/new", cookie,
  )
  assert_eq(response.code, 200)
  assert_true(response.headers.get("cache-control") is Some("no-store"))
  assert_true(response.headers.get("x-frame-options") is Some("DENY"))
  assert_true(!body.contains(cookie.value))
  extract_attr(body, "name=\"csrf_token\"", "value=\"")
}
