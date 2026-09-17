///|
async test "loads entry asset path map from vite manifest" {
  let asset_path_map = load_entry_to_asset_path_map(
    @web_testkit.test_assets_root,
  )
  assert_true(asset_path_map["src/app.css"].has_prefix("/assets/app_styles-"))
  assert_true(
    asset_path_map["src/custom-elements.tsx"].has_prefix(
      "/assets/custom-elements-",
    ),
  )
}

///|
test "public browser assets use immutable caching" {
  assert_eq(
    asset_cache_control("custom-elements.js"),
    "public, max-age=31536000, immutable",
  )
  assert_eq(
    asset_cache_control("custom-elements-Cba53Qon.js"),
    "public, max-age=31536000, immutable",
  )
}

///|
async test "serves browser assets from mounted assets app" {
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
    let stylesheet_path = @web_testkit.extract_attr(
      html, "<link rel=\"stylesheet\"", "href=\"",
    )
    let (stylesheet_response, stylesheet_body) = @http.get(
      "http://127.0.0.1:\{port}\{stylesheet_path}",
    )
    assert_eq(stylesheet_response.code, 200)
    assert_true(
      stylesheet_response.headers.get("content-type")
      is Some("text/css; charset=utf-8"),
    )
    assert_true(stylesheet_body.text().contains(".site-header"))
    let asset_path = custom_elements_tsx_asset_path(
      load_entry_to_asset_path_map(@web_testkit.test_assets_root),
    )
    assert_true(html.contains(asset_path))
    let (response, body) = @http.get("http://127.0.0.1:\{port}\{asset_path}")
    assert_eq(response.code, 200)
    assert_true(
      response.headers.get("content-type")
      is Some("text/javascript; charset=utf-8"),
    )
    assert_true(
      response.headers.get("cache-control")
      is Some("public, max-age=31536000, immutable"),
    )
    assert_true(body.text().contains("moonhub-commit-diff"))
    assert_true(body.text().contains("moonhub-file-view"))
  })
}

///|
async test "does not serve vite manifest as public asset" {
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
    let (get_response, _) = @http.get(
      "http://127.0.0.1:\{port}/assets/.vite/manifest.json",
    )
    assert_eq(get_response.code, 404)
    let head_response = @web_testkit.http_head(
      port, "/assets/.vite/manifest.json",
    )
    assert_eq(head_response.code, 404)
  })
}

///|
async test "serves browser assets from configured absolute path" {
  let repo_root = @fs.realpath(@web_testkit.test_repo_root)
  let assets_root = @fs.realpath(@web_testkit.test_assets_root)
  let app = @moonback.App(
    @web_testkit.browser_app_module,
    config=@web_testkit.test_app_config(repo_root~, assets_root~),
  )
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = @web_testkit.rendered_commit_page(port)
    assert_true(html.contains("/assets/custom-elements-"))
    let asset_path = custom_elements_tsx_asset_path(
      load_entry_to_asset_path_map(@web_testkit.test_assets_root),
    )
    assert_true(html.contains(asset_path))
    let (response, body) = @http.get("http://127.0.0.1:\{port}\{asset_path}")
    assert_eq(response.code, 200)
    assert_true(body.text().contains("moonhub-file-view"))
  })
}
