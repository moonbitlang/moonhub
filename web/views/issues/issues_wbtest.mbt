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
    let (reopened, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/issues/1/reopen",
      "csrf_token=\{token}&edit_version=2",
      alice,
    )
    assert_eq(reopened.code, 303)
    assert_eq(@collaboration.require_issue(pool, scope, 1L).status, "open")
  })
}

///|
async test "issue edit forms save changes and preserve validation and stale edit protection" {
  @web_testkit.with_repository_test_app((port, pool, _, alice, bob) => {
    let (_, form) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/issues/new", alice,
    )
    let csrf = @web_testkit.extract_attr(
      form, "name=\"csrf_token\"", "value=\"",
    )
    let (created, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/issues",
      "csrf_token=\{csrf}&title=Original&description=Original+description&assignee=0",
      alice,
    )
    assert_eq(created.code, 303)
    let (edit, html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/issues/1/edit", alice,
    )
    assert_eq(edit.code, 200)
    let action = @web_testkit.extract_attr(
      html, "<form class=\"form-stack mr-form\"", "action=\"",
    )
    assert_eq(action, "/alice/demo/issues/1/edit")
    let version = @web_testkit.extract_attr(
      html, "name=\"edit_version\"", "value=\"",
    )
    assert_eq(version, "1")
    let (forged, _) = @web_testkit.http_post_path_with_cookie(
      port,
      action,
      "edit_version=\{version}&title=Forged&assignee=0",
      alice,
    )
    assert_eq(forged.code, 403)
    let (denied, _) = @web_testkit.http_get_path_with_cookie(port, action, bob)
    assert_eq(denied.code, 404)
    let (saved, _) = @web_testkit.http_post_path_with_cookie(
      port,
      action,
      "csrf_token=\{csrf}&edit_version=\{version}&title=Edited+issue&description=Edited+description&assignee=1",
      alice,
    )
    assert_eq(saved.code, 303)
    assert_eq(saved.headers.get("location"), Some("/alice/demo/issues/1"))
    let scope = @repository.repository_scope(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      { owner: "alice", name: "demo", },
    )
    let issue = @collaboration.require_issue(pool, scope, 1L)
    assert_eq(issue.title, "Edited issue")
    assert_eq(issue.description, "Edited description")
    assert_eq(issue.assignee_id, 1L)
    assert_eq(issue.edit_version, 2L)
    let (_, reopened) = @web_testkit.http_get_path_with_cookie(
      port, action, alice,
    )
    assert_eq(
      @web_testkit.extract_attr(reopened, "name=\"title\"", "value=\""),
      "Edited issue",
    )
    assert_true(reopened.contains(">Edited description</textarea>"))
    assert_eq(
      @web_testkit.extract_attr(reopened, "name=\"edit_version\"", "value=\""),
      "2",
    )
    let (invalid, invalid_html) = @web_testkit.http_post_path_with_cookie(
      port,
      action,
      "csrf_token=\{csrf}&edit_version=2&title=+&description=Keep+my+draft&assignee=0",
      alice,
    )
    assert_eq(invalid.code, 400)
    assert_true(invalid_html.contains("title must be 1-200 characters"))
    assert_true(invalid_html.contains(">Keep my draft</textarea>"))
    let (stale, stale_html) = @web_testkit.http_post_path_with_cookie(
      port,
      action,
      "csrf_token=\{csrf}&edit_version=\{version}&title=Stale+title&description=Stale+draft&assignee=0",
      alice,
    )
    assert_eq(stale.code, 400)
    assert_true(stale_html.contains("this issue changed; reload before saving"))
    assert_true(stale_html.contains(">Stale draft</textarea>"))
    assert_eq(
      @web_testkit.extract_attr(stale_html, "name=\"edit_version\"", "value=\""),
      version,
    )
    let issue = @collaboration.require_issue(pool, scope, 1L)
    assert_eq(issue.title, "Edited issue")
    assert_eq(issue.description, "Edited description")
    assert_eq(issue.assignee_id, 1L)
    assert_eq(issue.edit_version, 2L)
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
