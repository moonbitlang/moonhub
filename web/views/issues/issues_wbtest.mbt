///|
async test "issue pages enforce repository permissions CSRF and output escaping" {
  @web_testkit.with_repository_test_app((port, pool, _, alice, bob) => {
    let (denied, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/issues", bob,
    )
    assert_eq(denied.code, 404)
    let (_, form) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/issues/new", alice,
    )
    let token = @web_testkit.extract_attr(
      form, "name=\"csrf_token\"", "value=\"",
    )
    let (forged, _) = @web_testkit.http_post_path_with_cookie(
      port, "/alice/demo/issues", "title=Issue&assignee=1", alice,
    )
    assert_eq(forged.code, 403)
    let (created, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/issues",
      "csrf_token=\{token}&title=Issue&description=%3Cscript%3Ebad%3C%2Fscript%3E&assignee=1",
      alice,
    )
    assert_eq(created.code, 303)
    assert_true(created.headers.get("location") is Some("/alice/demo/issues/1"))
    let (detail, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/issues/1", alice,
    )
    assert_eq(detail.code, 200)
    assert_true(detail.headers.get("cache-control") is Some("no-store"))
    assert_true(body.contains("&lt;script&gt;bad&lt;/script&gt;"))
    assert_true(!body.contains("<script>bad</script>"))
    let (commented, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/issues/1/comment",
      "csrf_token=\{token}&body=Details",
      alice,
    )
    assert_eq(commented.code, 303)
    let (closed, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/issues/1/close",
      "csrf_token=\{token}&edit_version=1",
      alice,
    )
    assert_eq(closed.code, 303)
    let (_, list) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/issues?status=closed&assigned=me&q=Issue", alice,
    )
    assert_true(list.contains("/alice/demo/issues/1"))
    let (stale, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/issues/1/reopen",
      "csrf_token=\{token}&edit_version=1",
      alice,
    )
    assert_eq(stale.code, 400)
    let scope = @repository.repository_scope(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      { owner: "alice", name: "demo", },
    )
    assert_eq(@collaboration.require_issue(pool, scope, 1L).status, "closed")
  })
}

///|
async test "issue descriptions and comments link references in their own repository" {
  @web_testkit.with_repository_test_app((port, _, _, alice, _) => {
    let (_, form) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/issues/new", alice,
    )
    let csrf = @web_testkit.extract_attr(
      form, "name=\"csrf_token\"", "value=\"",
    )
    let (created, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/issues",
      "csrf_token=\{csrf}&title=References&description=See+%2334+and+%2112&assignee=0",
      alice,
    )
    assert_eq(created.code, 303)
    let (commented, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/issues/1/comment",
      "csrf_token=\{csrf}&body=Related+%2356+and+%2178",
      alice,
    )
    assert_eq(commented.code, 303)
    let (detail, html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/issues/1", alice,
    )
    assert_eq(detail.code, 200)
    for
      path in [
        "issues/34", "merge-requests/12", "issues/56", "merge-requests/78",
      ] {
      assert_true(html.contains("href=\"/alice/demo/\{path}\""), msg=path)
    }
  })
}
