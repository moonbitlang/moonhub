///|
async test "production browser hides unregistered and unauthorized repositories" {
  @web_testkit.with_production_test_app((_, port, pool) => {
    let key = @identity.hash_password("sshBrowserPassword")
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO \"user\" (name_key, display_name, password_hash) VALUES ('ssh_browser', 'Browser', ?)",
        params=[key],
      )
      let _ = client.execute(
        "INSERT INTO team (name_key, display_name, kind) VALUES ('alice', 'Alice', 'personal')",
      )
      let _ = client.execute(
        "INSERT INTO repository (team_id, name, visibility) SELECT id, 'demo', 'private' FROM team WHERE name_key = 'alice'",
      )
    })
    let cookie = @web_testkit.login_test_user(
      port, "ssh_browser", "sshBrowserPassword",
    )
    let (index_response, index) = @web_testkit.http_get_path_with_cookie(
      port, "/", cookie,
    )
    assert_eq(index_response.code, 200)
    assert_true(!index.contains("alice/demo"))
    let (denied, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(denied.code, 404)
    pool.with_client(client => {
      let _ = client.execute("UPDATE repository SET visibility = 'public'")
    })
    let (allowed, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(allowed.code, 200)
    pool.with_client(client => {
      let _ = client.execute("DELETE FROM repository")
    })
    let (unregistered, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(unregistered.code, 404)
  })
}

///|
async test "new empty repositories have browsable files and commits pages" {
  @test_support.with_ssh_test_db(pool => {
    let root = @fs.tmpdir(prefix="moonhub-empty-")
    defer @fs.rmdir(root, recursive=true)
    @repository.create_managed_repository(
      pool,
      root,
      { owner: "alice", name: "empty", },
      "private",
      false,
    )
    let token = pool.with_client(client => {
      client.with_transaction(tx => @identity.create_session_token(tx, 1L))
    })
    let app = @moonback.App(
      @web.app_module,
      config=@moonback.Config(custom=[
        @moonback.Config::custom(@web_context.config_root, root),
        @moonback.Config::custom(
          @web_context.config_assets_root, @web_testkit.test_assets_root,
        ),
        @moonback.Config::custom(@web_context.config_db_pool, pool),
      ]),
    )
    defer app.close()
    @async.with_task_group(group => {
      let listener = @moonback.listen(port=0)
      let server = group.spawn(() => app.serve(listener))
      defer server.cancel()
      let cookie = @web_context.session_cookie(token)
      let (files, files_body) = @web_testkit.http_get_path_with_cookie(
        listener.addr.port(),
        "/alice/empty",
        cookie,
      )
      assert_eq(files.code, 200)
      assert_true(files_body.contains("No files."))
      let (commits, commits_body) = @web_testkit.http_get_path_with_cookie(
        listener.addr.port(),
        "/alice/empty/commits",
        cookie,
      )
      assert_eq(commits.code, 200)
      assert_true(commits_body.contains("No commits."))
      let (invalid, _) = @web_testkit.http_get_path_with_cookie(
        listener.addr.port(),
        "/alice/empty/tree/missing",
        cookie,
      )
      assert_eq(invalid.code, 404)
    })
  })
}
