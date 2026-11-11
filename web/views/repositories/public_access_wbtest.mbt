///|
async test "production browser serves public repositories anonymously and rechecks visibility" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository SET visibility = 'public' WHERE name = 'demo'",
      )
    })
    @repository.create_managed_repository(
      pool,
      root,
      { owner: "alice", name: "secret", },
      "private",
      false,
    )
    @repository.create_managed_repository(
      pool,
      root,
      { owner: "alice", name: "pending", },
      "public",
      false,
    )
    @repository.create_managed_repository(
      pool,
      root,
      { owner: "alice", name: "unregistered", },
      "public",
      false,
    )
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository SET ready = 0 WHERE name = 'pending'",
      )
      let _ = client.execute(
        "DELETE FROM repository WHERE name = 'unregistered'",
      )
    })
    let commit = @gitops.run_git(root + "/alice/demo.git", [
        "rev-parse", "master",
      ])
      .trim()
      .to_owned()
    let routes = [
      "/alice/demo",
      "/alice/demo/tree",
      "/alice/demo/tree/master",
      "/alice/demo/tree/master/src",
      "/alice/demo/blob/master/src/main.mbt",
      "/alice/demo/commits",
      "/alice/demo/commit/\{commit}",
    ]
    for path in routes {
      let (response, body) = @web_testkit.http_get_path(port, path)
      assert_eq(response.code, 200, msg=path + body)
      assert_true(body.contains("href=\"/-/login\""), msg=path)
      assert_true(!body.contains("/settings/deploy-keys"), msg=path)
    }
    for path in ["/", "/alice"] {
      let (response, body) = @web_testkit.http_get_path(port, path)
      assert_eq(response.code, 200, msg=body)
      assert_true(body.contains("href=\"/alice/demo\""))
      assert_true(!body.contains("/alice/secret"))
      assert_true(!body.contains("/alice/pending"))
      assert_true(!body.contains("/alice/unregistered"))
      assert_true(!body.contains("/alice/-/repositories/new"))
    }
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let response = client.get("/alice/demo/blob/master/src/main.mbt", extra_headers={
      "Accept": "application/vnd.moonhub.page+json",
    })
    let body = client.read_all().text()
    assert_eq(response.code, 200, msg=body)
    assert_eq(
      response.headers.get("content-type"),
      Some("application/vnd.moonhub.page+json"),
    )
    assert_eq(response.headers.get("cache-control"), Some("no-store"))
    assert_true(body.contains("println"))
    let stale_cookie = @web_context.session_cookie("expired-session")
    assert_eq(
      @web_testkit.http_get_path_with_cookie(port, "/alice/demo", stale_cookie).0.code,
      200,
    )
    for
      path in [
        "/alice/secret", "/alice/pending", "/alice/unregistered", "/alice/missing",
      ] {
      let (response, body) = @web_testkit.http_get_path(port, path)
      assert_eq(response.code, 404, msg=path + body)
      assert_eq(@web_testkit.http_head(port, path).code, 404, msg=path)
    }
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository SET visibility = 'private' WHERE name = 'demo'",
      )
    })
    for path in routes {
      assert_eq(@web_testkit.http_get_path(port, path).0.code, 404, msg=path)
    }
    for path in ["/", "/alice"] {
      let (response, body) = @web_testkit.http_get_path(port, path)
      assert_eq(response.code, 200)
      assert_true(!body.contains("href=\"/alice/demo\""))
    }
  })
}

///|
async test "anonymous browsing never opens account management team data or write routes" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO repository (team_id, name, visibility) VALUES (3, 'org-public', 'public'), (3, 'org-private', 'private')",
      )
    })
    let (response, body) = @web_testkit.http_get_path(port, "/workshop")
    assert_eq(response.code, 200)
    assert_true(body.contains("/workshop/org-public"))
    assert_true(!body.contains("/workshop/org-private"))
    assert_true(!body.contains(">Members<"))
    assert_true(!body.contains(">Invitations<"))
    for
      path in [
        "/-/settings/profile", "/-/settings/ssh-keys", "/-/teams", "/-/admin/settings/ssh",
        "/-/notifications", "/workshop?tab=members", "/workshop?tab=invitations",
        "/alice/-/repositories/new", "/alice/demo/settings/deploy-keys", "/alice/demo/issues/new",
      ] {
      let (response, _) = @web_testkit.http_get_path(port, path)
      assert_eq(response.code, 303, msg=path)
      assert_eq(response.headers.get("location"), Some("/-/login"), msg=path)
    }
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    for
      path in [
        "/", "/alice/demo", "/alice/-/repositories", "/alice/demo/issues", "/workshop/-/invitations",
      ] {
      let response = client.post(path, "name=anonymous-write", extra_headers={
        "Content-Type": "application/x-www-form-urlencoded",
      })
      client.skip_response_body()
      assert_eq(response.code, 303, msg=path)
      assert_eq(response.headers.get("location"), Some("/-/login"), msg=path)
    }
  })
}

///|
async test "anonymous structured commit diffs enforce repository visibility" {
  @web_testkit.with_repository_test_app(
    (port, pool, root, _, _) => {
      let commit = @gitops.run_git(root + "/alice/demo.git", [
          "rev-parse", "master",
        ])
        .trim()
        .to_owned()
      let path = "/alice/demo/commit/\{commit}/diff?fixed=1"
      assert_eq(@web_testkit.http_get_path(port, path).0.code, 404)
      pool.with_client(client => {
        let _ = client.execute(
          "UPDATE repository SET visibility = 'public' WHERE name = 'demo'",
        )
      })
      let (response, body) = @web_testkit.http_get_path(port, path)
      assert_eq(response.code, 200, msg=body)
      assert_eq(response.headers.get("cache-control"), Some("no-store"))
      assert_true(body.contains("README.md"))
    },
    moondiff=true,
  )
}
