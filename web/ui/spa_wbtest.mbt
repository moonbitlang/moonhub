///|
async test "direct visits SSR and negotiated navigation share authorized page content" {
  @web_testkit.with_ssh_settings_app((port, _, alice, bob, _) => {
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    for
      (path, cookie, expected) in [
        ("/alice/demo", alice, 200),
        ("/-/settings/profile", alice, 200),
        ("/workshop?tab=members", bob, 403),
        ("/workshop?tab=unknown", alice, 400),
        ("/missing", alice, 404),
      ] {
      let response = client.get(path, extra_headers={
        "Cookie": "\{cookie.name}=\{cookie.value}",
        "Accept": "application/vnd.moonhub.page+json",
      })
      assert_eq(response.code, expected)
      assert_eq(
        response.headers.get("content-type"),
        Some("application/vnd.moonhub.page+json"),
      )
      assert_eq(response.headers.get("cache-control"), Some("no-store"))
      assert_true(response.headers.get("vary").unwrap_or("").contains("Accept"))
      let body = client.read_all().text()
      let page : @spa.Page = @json.from_json(@json.parse(body))
      assert_true(!page.body.is_empty())
      assert_true(!body.contains(cookie.value))
    }
    let (response, html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", alice,
    )
    assert_eq(response.code, 200)
    assert_true(html.has_prefix("<!DOCTYPE html>"))
    assert_true(html.contains("id=\"moonhub-page\""))
    assert_true(html.contains("id=\"moonhub-bootstrap\""))
    assert_true(html.contains("id=\"main-content\""))
    assert_true(html.contains("href=\"/alice/demo/issues\""))
    let marker = "id=\"moonhub-bootstrap\""
    let script = html[html.find(marker).unwrap():]
    let content = script[script.find(">").unwrap() + 1:]
    let json = content[:content.find("</script>").unwrap()].to_owned()
    let initial : @spa.Page = @json.from_json(@json.parse(json))
    assert_true(!initial.body.is_empty())
    assert_true(!json.contains("<"))
  })
}
