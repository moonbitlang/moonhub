///|
async test "runner group forms enforce administrator CSRF and revision authorization" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, admin_cookie) => {
    let coordinator = @runtime.Coordinator::new(pool)
    let admin = @identity.active_user_by_name(pool, "admin")
    let provider = coordinator.create_provider(
      admin,
      "group-provider",
      "d".repeat(64),
      ["self-hosted", "linux"],
      [{ owner: "alice", name: "demo", }],
    )
    let route = "/-/admin/pipelines/groups"
    let (page, body) = @web_testkit.http_get_path_with_cookie(
      port, route, admin_cookie,
    )
    assert_eq(page.code, 200)
    assert_eq(page.headers.get("cache-control"), Some("no-store"))
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let (denied, _) = @web_testkit.http_get_path_with_cookie(port, route, alice)
    assert_eq(denied.code, 403)
    let fields = "name=trusted&revision=0&providers=group-provider&repositories=alice/demo"
    let (missing_csrf, _) = @web_testkit.http_post_path_with_cookie(
      port, route, fields, admin_cookie,
    )
    assert_eq(missing_csrf.code, 403)
    let (forbidden, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&" + fields,
      alice,
    )
    assert_eq(forbidden.code, 403)
    let (saved, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&" + fields,
      admin_cookie,
    )
    assert_eq(saved.code, 303)
    assert_eq(coordinator.runner_groups(admin)[0].providers, [provider.id])
    let (stale, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&" + fields,
      admin_cookie,
    )
    assert_eq(stale.code, 409)
    let (invalid, error_body) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&name=trusted&revision=1&providers=%3Cscript%3E",
      admin_cookie,
    )
    assert_eq(invalid.code, 400)
    assert_true(error_body.contains("&lt;script&gt;"))
    assert_false(error_body.contains("value=\"<script>\""))
    assert_eq(coordinator.runner_groups(admin)[0].revision, 1L)
  })
}
