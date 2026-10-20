///|
async test "webhook forms preserve validation errors enforce CSRF and hide signing secrets" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, bob, _) => {
    let route = "/alice/demo/settings/webhooks"
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port,
      route + "/new",
      alice,
    )
    assert_eq(response.code, 200)
    assert_eq(response.headers.get("cache-control"), Some("no-store"))
    let token = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let form = "csrf_token=\{token}&url=https%3A%2F%2Fexample.com%2Fhook&secret=0123456789abcdef&event_push=1&active=1"
    let (created, _) = @web_testkit.http_post_path_with_cookie(
      port, route, form, alice,
    )
    assert_eq(created.code, 303)
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let hook = @webhooks.list_hooks(pool, actor, repo)[0]
    let (listed, body) = @web_testkit.http_get_path_with_cookie(
      port, route, alice,
    )
    assert_eq(listed.code, 200)
    assert_true(body.contains("https://example.com/hook"))
    assert_false(body.contains("0123456789abcdef"))
    let (edit, body) = @web_testkit.http_get_path_with_cookie(
      port,
      "\{route}/\{hook.id}",
      alice,
    )
    assert_eq(edit.code, 200)
    assert_false(body.contains("0123456789abcdef"))
    let (invalid, body) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=\{token}&url=ftp%3A%2F%2Fexample.com&secret=0123456789abcdef&event_push=1",
      alice,
    )
    assert_eq(invalid.code, 400)
    assert_true(body.contains("ftp://example.com"))
    assert_false(body.contains("0123456789abcdef"))
    let (csrf, _) = @web_testkit.http_post_path_with_cookie(
      port, route, "url=https%3A%2F%2Fexample.com&secret=0123456789abcdef&event_push=1",
      alice,
    )
    assert_eq(csrf.code, 403)
    let (outside, _) = @web_testkit.http_get_path_with_cookie(port, route, bob)
    assert_eq(outside.code, 404)
    let (pinged, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "\{route}/\{hook.id}/ping",
      "csrf_token=\{token}",
      alice,
    )
    assert_eq(pinged.code, 303)
    let (deliveries, body) = @web_testkit.http_get_path_with_cookie(
      port,
      "\{route}/\{hook.id}/deliveries",
      alice,
    )
    assert_eq(deliveries.code, 200)
    assert_true(body.contains("pending"))
    let (deleted, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "\{route}/\{hook.id}/delete",
      "csrf_token=\{token}&version=1",
      alice,
    )
    assert_eq(deleted.code, 303)
    assert_true(@webhooks.list_hooks(pool, actor, repo).is_empty())
  })
}
