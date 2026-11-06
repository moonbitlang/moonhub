///|
pub async fn with_repository_test_app(
  f : async (Int32, @database.Database, String, @http.Cookie, @http.Cookie) -> Unit,
  moondiff~ : Bool = false,
  diff_executor? : @gitops.DiffExecutor,
) -> Unit {
  @test_support.with_ssh_test_db(pool => {
    @test_support.with_git_test_repo((root, _) => {
      let cookies = pool.with_client(client => {
        client.with_transaction(tx => {
          [1L, 2L].map(id => {
            @web_context.session_cookie(@identity.create_session_token(tx, id))
          })
        })
      })
      let app = @moonback.App(
        @web.app_module,
        config=@moonback.Config(custom=[
          @moonback.Config::custom(@web_context.diff_enabled_key, moondiff),
          @moonback.Config::custom(
            @web_context.diff_executor_key,
            diff_executor.unwrap_or_else(() => {
              @gitops.DiffExecutor::new(
                worker="_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe",
              )
            }),
          ),
          @moonback.Config::custom(@web_context.config_root, root),
          @moonback.Config::custom(
            @web_context.config_assets_root, test_assets_root,
          ),
          @moonback.Config::custom(@web_context.config_db_pool, pool),
        ]),
      )
      defer app.close()
      @async.with_task_group(group => {
        let listener = @moonback.listen(port=0)
        let server = group.spawn(() => app.serve(listener))
        defer server.cancel()
        f(listener.addr.port(), pool, root, cookies[0], cookies[1])
      })
    })
  })
}

///|
pub async fn repository_test_token(
  port : Int32,
  team : String,
  cookie : @http.Cookie,
) -> String {
  let (response, body) = http_get_path_with_cookie(
    port,
    "/\{team}/-/repositories/new",
    cookie,
  )
  assert_eq(response.code, 200)
  extract_attr(body, "name=\"csrf_token\"", "value=\"")
}
