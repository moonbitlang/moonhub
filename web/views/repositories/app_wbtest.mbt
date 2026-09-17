///|
async test "initializes app module" {
  let app = @moonback.App(
    @web_testkit.browser_app_module,
    config=@web_testkit.test_app_config(),
  )
  defer app.close()
}

///|
async test "serves repository paths from route params" {
  let app = @moonback.App(
    @web_testkit.browser_app_module,
    config=@web_testkit.test_app_config(),
  )
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = @web_testkit.rendered_blob_page(port)
    assert_true(html.contains("println(&quot;hi&quot;)"))
  })
}

///|
async test "serves slash branches and tags in repository URLs" {
  @test_support.with_git_test_repo(async fn(root, git_dir) {
    let branch = "yuxiang/regex-states-overflow-fallback"
    ignore(
      @gitops.run_git(git_dir, ["update-ref", "refs/heads/\{branch}", "master"]),
    )
    ignore(
      @gitops.run_git(git_dir, ["update-ref", "refs/tags/release", "master"]),
    )
    ignore(
      @gitops.run_git(git_dir, ["update-ref", "refs/heads/release/v1", "master"]),
    )
    ignore(
      @gitops.run_git(git_dir, ["update-ref", "refs/tags/releases/v2", "master"]),
    )
    let commit = @gitops.run_git(git_dir, ["rev-parse", "master"])
      .trim()
      .to_owned()
    let app = @moonback.App(
      @web_testkit.browser_app_module,
      config=@web_testkit.test_app_config(repo_root=root),
    )
    defer app.close()
    @async.with_task_group(group => {
      let server = @moonback.listen(port=0)
      let task = group.spawn(() => app.serve(server))
      defer task.cancel()
      let port = server.addr.port()
      for rev in [branch, "release/v1", "releases/v2", "master", "HEAD", commit] {
        let (response, body) = @web_testkit.http_get_path(
          port,
          "/alice/demo/blob/\{rev}/src/main.mbt",
        )
        assert_eq(response.code, 200, msg=body)
        assert_true(
          body.contains("<span data-file-name hidden>src/main.mbt</span>"),
        )
        assert_true(body.contains("println(&quot;hi&quot;)"))
        let (response, body) = @web_testkit.http_get_path(
          port,
          "/alice/demo/tree/\{rev}",
        )
        assert_eq(response.code, 200, msg=body)
        assert_true(body.contains("/alice/demo/tree/\{rev}/src"))
        let (response, body) = @web_testkit.http_get_path(
          port,
          "/alice/demo/tree/\{rev}/src",
        )
        assert_eq(response.code, 200, msg=body)
        assert_true(body.contains("/alice/demo/blob/\{rev}/src/main.mbt"))
      }
      let (response, body) = @web_testkit.http_get_path(
        port,
        "/alice/demo?rev=\{branch}",
      )
      assert_eq(response.code, 200, msg=body)
      assert_true(body.contains("/alice/demo/blob/\{branch}/README.md"))
      let (response, body) = @web_testkit.http_get_path(
        port,
        "/alice/demo/commits?rev=\{branch}",
      )
      assert_eq(response.code, 200, msg=body)
      assert_true(body.contains("initial fixture commit"))
      let (response, _) = @web_testkit.http_get_path(
        port, "/alice/demo?rev=missing/branch",
      )
      assert_eq(response.code, 404)
      let (response, _) = @web_testkit.http_get_path(
        port,
        "/alice/demo/blob/\{branch}/missing.mbt",
      )
      assert_eq(response.code, 404)
      let (response, _) = @web_testkit.http_get_path(
        port,
        "/alice/demo/blob/\{branch}",
      )
      assert_eq(response.code, 404)
      let (response, _) = @web_testkit.http_get_path(
        port,
        "/alice/demo/blob/\{branch}/../README.md",
      )
      assert_eq(response.code, 400)
      let (response, _) = @web_testkit.http_get_path(
        port, "/alice/demo/blob/releases/v20/src/main.mbt",
      )
      assert_eq(response.code, 404)
      ignore(
        @gitops.run_git(git_dir, [
          "symbolic-ref",
          "HEAD",
          "refs/heads/\{branch}",
        ]),
      )
      let (response, body) = @web_testkit.http_get_path(port, "/alice/demo")
      assert_eq(response.code, 200, msg=body)
      assert_true(body.contains("/alice/demo/blob/\{branch}/README.md"))
    })
  })
}

///|
async test "invalid route params return bad request" {
  let app = @moonback.App(
    @web_testkit.browser_app_module,
    config=@web_testkit.test_app_config(),
  )
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let (response, body) = @web_testkit.http_get_path(
      port, "/alice/demo/tree/.",
    )
    assert_eq(response.code, 400)
    assert_true(body.contains("invalid revision"))
  })
}

///|
async test "missing repositories return not found" {
  let app = @moonback.App(
    @web_testkit.browser_app_module,
    config=@web_testkit.test_app_config(),
  )
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let (response, body) = @web_testkit.http_get_path(port, "/alice/missing")
    assert_eq(response.code, 404)
    assert_true(body.contains("repository not found"))
  })
}

///|
async test "missing git resources return not found" {
  let app = @moonback.App(
    @web_testkit.browser_app_module,
    config=@web_testkit.test_app_config(),
  )
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let (blob_response, blob_body) = @web_testkit.http_get_path(
      port, "/alice/demo/blob/master/missing.mbt",
    )
    assert_eq(blob_response.code, 404)
    assert_true(blob_body.contains("file not found"))
    let (tree_response, tree_body) = @web_testkit.http_get_path(
      port, "/alice/demo/tree/master/missing",
    )
    assert_eq(tree_response.code, 404)
    assert_true(tree_body.contains("tree not found"))
    let (commit_response, commit_body) = @web_testkit.http_get_path(
      port, "/alice/demo/commit/not-a-real-commit",
    )
    assert_eq(commit_response.code, 404)
    assert_true(commit_body.contains("commit not found"))
  })
}

///|
async test "blob page includes rich file custom element" {
  let app = @moonback.App(
    @web_testkit.browser_app_module,
    config=@web_testkit.test_app_config(),
  )
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = @web_testkit.rendered_blob_page(port)
    assert_true(html.contains("https://fonts.googleapis.com"))
    assert_true(html.contains("family=M+PLUS+Code+Latin"))
    assert_true(html.contains("rel=\"modulepreload\""))
    assert_true(html.contains("blocking=\"render\""))
    assert_true(html.contains("fetchpriority=\"high\""))
    assert_true(html.contains("/assets/custom-elements-"))
    assert_true(html.contains("<moonhub-file-view>"))
    assert_true(
      html.contains("<span data-file-name hidden>src/main.mbt</span>"),
    )
    assert_true(html.contains("<pre data-file-content>"))
  })
}

///|
async test "commit page includes rich diff custom element" {
  let app = @moonback.App(
    @web_testkit.browser_app_module,
    config=@web_testkit.test_app_config(),
  )
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = @web_testkit.rendered_commit_page(port)
    assert_true(html.contains("https://fonts.googleapis.com"))
    assert_true(html.contains("family=M+PLUS+Code+Latin"))
    assert_true(html.contains("rel=\"modulepreload\""))
    assert_true(html.contains("blocking=\"render\""))
    assert_true(html.contains("fetchpriority=\"high\""))
    assert_true(html.contains("/assets/custom-elements-"))
    assert_true(html.contains("<moonhub-commit-diff>"))
    assert_true(html.contains("<pre data-patch>diff --git "))
    assert_true(!html.contains("files changed"))
  })
}
