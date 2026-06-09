///|
let test_repo_root : String = "testdata/repos"

///|
let test_assets_root : String = "assets"

///|
fn test_app_config(
  repo_root? : String = test_repo_root,
  assets_root? : String = test_assets_root,
) -> @moonback.Config {
  Config(custom=[
    @moonback.Config::custom(config_root, repo_root),
    @moonback.Config::custom(config_assets_root, assets_root),
  ])
}

///|
async test "initializes app module" {
  let app = @moonback.App(app_module, config=test_app_config())
  defer app.close()
}

///|
test "assets is a reserved repository owner" {
  assert_true(valid_repo_owner("alice"))
  assert_true(!valid_repo_owner(public_assets_owner))
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
async fn rendered_blob_page(port : Int) -> String {
  let (response, body) = @http.get(
    "http://127.0.0.1:\{port}/alice/demo/blob/master/src/main.mbt",
  )
  assert_eq(response.code, 200)
  body.text()
}

///|
async test "serves repository paths from route params" {
  let app = @moonback.App(app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = rendered_blob_page(port)
    assert_true(html.contains("println(&quot;hi&quot;)"))
  })
}

///|
fn extract_attr(html : String, marker : String, attr : String) -> String {
  match html.find(marker) {
    Some(marker_start) => {
      let attr_start = marker_start + html[marker_start:].find(attr).unwrap()
      let value_start = attr_start + attr.length()
      let value_end = value_start + html[value_start:].find("\"").unwrap()
      html[value_start:value_end].to_owned()
    }
    None => abort("missing marker")
  }
}

///|
async fn rendered_commit_page(port : Int) -> String {
  let commits = list_commits("\{test_repo_root}/alice/demo.git", "master")
  let (response, body) = @http.get(
    "http://127.0.0.1:\{port}/alice/demo/commit/\{commits[0].hash}",
  )
  assert_eq(response.code, 200)
  body.text()
}

///|
async fn http_head(port : Int, path : String) -> @http.Response {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  client..request(Head, path).end_request()
}

///|
async test "serves browser assets from mounted assets app" {
  let app = @moonback.App(app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = rendered_commit_page(port)
    let asset_path = extract_attr(html, "<script type=\"module\"", "src=\"")
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
  let app = @moonback.App(app_module, config=test_app_config())
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
    let head_response = http_head(port, "/assets/.vite/manifest.json")
    assert_eq(head_response.code, 404)
  })
}

///|
async test "serves browser assets from configured absolute path" {
  let repo_root = @fs.realpath(test_repo_root)
  let assets_root = @fs.realpath(test_assets_root)
  let app = @moonback.App(
    app_module,
    config=test_app_config(repo_root~, assets_root~),
  )
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = rendered_commit_page(port)
    assert_true(html.contains("/assets/custom-elements-"))
    let asset_path = extract_attr(html, "<script type=\"module\"", "src=\"")
    let (response, body) = @http.get("http://127.0.0.1:\{port}\{asset_path}")
    assert_eq(response.code, 200)
    assert_true(body.text().contains("moonhub-file-view"))
  })
}

///|
async test "blob page includes rich file custom element" {
  let app = @moonback.App(app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = rendered_blob_page(port)
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
  let app = @moonback.App(app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = rendered_commit_page(port)
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
