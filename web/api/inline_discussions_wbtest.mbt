///|
async test "anchored discussions preserve snapshot scope lifecycle and notification landing" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let token = @identity.create_access_token(pool, actor, "inline", "write", 1)
    let outsider = @identity.create_access_token(
      pool, bob, "outside", "write", 1,
    )
    let scope = @repository.repository_scope(pool, actor, {
      owner: "alice",
      name: "demo",
    })
    let dir = "\{root}/alice/demo.git"
    let base = @gitops.branch_sha(dir, "master")
    let first = @test_support.merge_test_commit(
      dir, "feature", base, "one\ntwo\nthree\n",
    )
    let head = @test_support.merge_test_commit(
      dir, "feature", first, "inserted\none\nchanged\nthree\n",
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, dir, actor, "Inline", "", "feature", "master", false,
    )
    let api = "/repos/alice/demo/mrs/1"
    let body : Json = {
      "version": "1",
      "commit": head,
      "path": "README.md",
      "side": "old",
      "start_line": "2",
      "end_line": "2",
      "body": "Please check this line",
    }
    let (status, _) = api_test_request(
      port,
      api + "/inline-comment",
      outsider,
      Some(body),
    )
    assert_eq(status, 404)
    let (status, created) = api_test_request(
      port,
      api + "/inline-comment",
      token,
      Some(body),
    )
    assert_eq(status, 200)
    guard created
      is {
        "discussion": {
          "id": String(id),
          "anchor": {
            "base_sha": String(base_sha),
            "head_sha": String(head_sha),
            "context": String(context),
            "start_line": String("2"),
            ..
          },
          ..
        },
        ..
      } else {
      fail("missing anchor")
    }
    assert_eq(base_sha, first)
    assert_eq(head_sha, head)
    assert_eq(context, "2: two\n")
    let url = "/alice/demo/merge-requests/1"
    let (landing, _) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?discussion=" + id,
      cookie,
    )
    assert_eq(landing.code, 303)
    assert_true(
      landing.headers
      .get("location")
      .unwrap()
      .contains("tab=changes&version=1&commit=" + head + "&discussion=" + id),
    )
    let (status, html) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?tab=changes&version=1&commit=" + head,
      cookie,
    )
    assert_eq(status.code, 200)
    assert_true(html.contains("Please check this line"))
    assert_true(html.contains("data-inline-thread"))
    let (_, full) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?tab=changes&version=1",
      cookie,
    )
    assert_true(!full.contains("Please check this line"))
    let (status, _) = api_test_request(
      port,
      api + "/reply",
      token,
      Some({ "discussion": id, "body": "Reply" }),
    )
    assert_eq(status, 200)
    let (status, _) = api_test_request(
      port,
      api + "/resolve-discussion",
      token,
      Some({ "discussion": id, "state_version": "1" }),
    )
    assert_eq(status, 200)
    let (status, _) = api_test_request(
      port,
      api + "/delete-comment",
      token,
      Some({ "comment": id, "version": "1" }),
    )
    assert_eq(status, 200)
    let (status, detail) = api_test_request(
      port,
      api + "/discussions?discussion=" + id,
      token,
      None,
    )
    assert_eq(status, 200)
    assert_true(
      detail
      is {
        "discussion": {
          "resolved": True,
          "anchor": { "context": String("2: two\n"), .. },
          "reply_count": String("1"),
          ..
        },
        ..
      },
    )
    ignore(@test_support.merge_test_commit(dir, "feature", base, "rewritten\n"))
    let current = @collaboration.refresh_merge_request(pool, scope, dir, mr)
    assert_eq(current.version, 2L)
    let (_, history) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?tab=changes&version=1&commit=" + head + "&discussion=" + id,
      cookie,
    )
    assert_true(history.contains("Viewing an older version"))
    assert_true(history.contains("2: two"))
    let (status, _) = api_test_request(
      port,
      api + "/inline-comment",
      token,
      Some({
        "version": "1",
        "path": "README.md",
        "side": "new",
        "start_line": "999",
        "end_line": "999",
        "body": "bad",
      }),
    )
    assert_eq(status, 400)
    let (_, page) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?tab=changes&version=1&commit=" + head,
      cookie,
    )
    let csrf = @web_testkit.extract_attr(
      page, "name=\"csrf_token\"", "value=\"",
    )
    let (status, _) = @web_testkit.http_post_path_with_cookie(
      port,
      url + "/inline-comment",
      "version=1&path=README.md&side=new&start_line=1&end_line=1&body=Native",
      cookie,
    )
    assert_eq(status.code, 403)
    let (invalid, retained) = @web_testkit.http_post_path_with_cookie(
      port,
      url + "/inline-comment",
      "csrf_token=" +
      csrf +
      "&version=1&commit=" +
      head +
      "&path=README.md&side=old&start_line=999&end_line=999&body=Keep+my+comment",
      cookie,
    )
    assert_eq(invalid.code, 400)
    assert_true(retained.contains("Keep my comment"))
    assert_true(retained.contains("value=\"999\""))
    assert_true(retained.contains("value=\"old\" selected"))
    let (status, _) = @web_testkit.http_post_path_with_cookie(
      port,
      url + "/inline-comment",
      "csrf_token=" +
      csrf +
      "&version=1&commit=" +
      head +
      "&path=README.md&side=new&start_line=1&end_line=1&body=Native",
      cookie,
    )
    assert_eq(status.code, 303)
    assert_true(
      @collaboration.list_merge_activity(pool, current, 1L).length() >= 5,
    )
  })
}
