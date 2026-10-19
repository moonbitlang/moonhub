///|
async test "API dumps inline images and browser reads inherit repository permissions" {
  @web_testkit.with_repository_test_app((
    port,
    pool,
    _,
    alice_cookie,
    bob_cookie,
  ) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let write = @identity.create_access_token(pool, alice, "images", "write", 1)
    let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII="
    let (created, json) = api_test_request(
      port,
      "/repos/alice/demo/issues",
      write,
      Some({
        "title": "Image issue",
        "description": "![pixel](data:image/png;base64,\{png})",
      }),
    )
    assert_eq(created, 200)
    guard json is { "description": String(description), .. } else {
      fail("missing converted description")
    }
    assert_false(description.contains("data:"))
    let images = @attachments.image_links(description)
    assert_eq(images.length(), 1)
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let response = client.get(images[0].url, extra_headers={
      "Cookie": "\{alice_cookie.name}=\{alice_cookie.value}",
    })
    assert_eq(response.code, 200)
    assert_eq(response.headers.get("content-type"), Some("image/png"))
    assert_eq(response.headers.get("cache-control"), Some("private, no-store"))
    assert_true(client.read_all().binary().length() > 20)
    let (denied, _) = @web_testkit.http_get_path_with_cookie(
      port,
      images[0].url,
      bob_cookie,
    )
    assert_eq(denied.code, 404)
    let (detail, html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/issues/1", alice_cookie,
    )
    assert_eq(detail.code, 200)
    assert_true(html.contains("<img src=\"\{images[0].url}\""))
    let (commented, _) = api_test_request(
      port,
      "/repos/alice/demo/issues/1/comment",
      write,
      Some({ "body": description }),
    )
    assert_eq(commented, 200)
    assert_eq(
      pool.with_client(client => {
        client
        .query_all("SELECT attachment_id FROM attachment_reference")
        .length()
      }),
      2,
    )
    let (invalid, _) = api_test_request(
      port,
      "/repos/alice/demo/issues",
      write,
      Some({
        "title": "Bad image",
        "description": "![bad](data:image/svg+xml;base64,AAAA)",
      }),
    )
    assert_eq(invalid, 400)
    let (cross_repo, _) = api_test_request(
      port,
      "/repos/alice/public/issues",
      write,
      Some({ "title": "Leak", "description": description }),
    )
    assert_eq(cross_repo, 400)
    let (_, form) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/issues/new", alice_cookie,
    )
    let csrf = @web_testkit.extract_attr(
      form, "name=\"csrf_token\"", "value=\"",
    )
    let forged = client.post("/alice/demo/attachments", "bad", extra_headers={
      "Cookie": "\{alice_cookie.name}=\{alice_cookie.value}",
    })
    assert_eq(forged.code, 403)
    ignore(client.read_all())
    let invalid_image = client.post("/alice/demo/attachments", "<svg></svg>", extra_headers={
      "Cookie": "\{alice_cookie.name}=\{alice_cookie.value}",
      "X-CSRF-Scope": "issues",
      "X-CSRF-Token": csrf,
    })
    assert_eq(invalid_image.code, 400)
    assert_true(client.read_all().text().contains("only PNG"))
    assert_eq(
      pool.with_client(client => {
        client.query_all("SELECT id FROM issue").length()
      }),
      1,
    )
  })
}
