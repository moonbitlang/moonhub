///|
async test "MR discussion API and browser enforce scopes state versions and CSRF" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let bob = @identity.active_user_by_name(pool, "bob")
    let write = @identity.create_access_token(pool, alice, "author", "write", 1)
    let read = @identity.create_access_token(pool, alice, "reader", "read", 1)
    let contributor_token = @identity.create_access_token(
      pool, bob, "member", "write", 1,
    )
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let dir = repo.git_dir(root)
    let base = @gitops.branch_sha(dir, "master")
    ignore(@test_support.merge_test_commit(dir, "threads", base, "first\n"))
    let mr = @collaboration.create_merge_request(
      pool, scope, dir, alice, "Threads", "", "threads", "master", false,
    )
    @collaboration.submit_merge_review(
      pool, admin, mr, 1L, "changes_requested", "Review concern",
    )
    let id = @collaboration.list_merge_discussions(pool, scope, alice, mr, 1L)[0].id.to_string()
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id, user_id, role) VALUES (?, ?, 'member')",
          params=[scope.team_id, bob.id],
        ),
      )
    })
    let path = "/repos/alice/demo/mrs/1"
    let (listed, result) = api_test_request(
      port,
      path + "/discussions",
      read,
      None,
    )
    assert_eq(listed, 200)
    assert_true(
      result
      is {
        "items": Array(
          [
            {
              "id": String(value),
              "state_version": String("1"),
              "resolved": False,
              ..
            },
          ]
        ),
        "unresolved_count": String("1"),
        ..
      } &&
      value == id,
    )
    let (denied, _) = api_test_request(
      port,
      path + "/reply",
      read,
      Some({ "discussion": id, "body": "Denied" }),
    )
    assert_eq(denied, 403)
    let (denied, _) = api_test_request(
      port,
      path + "/resolve-discussion",
      contributor_token,
      Some({ "discussion": id, "state_version": "1" }),
    )
    assert_eq(denied, 403)
    let (invalid, _) = api_test_request(
      port,
      path + "/reply",
      write,
      Some({ "discussion": id, "body": " " }),
    )
    assert_eq(invalid, 400)
    let (invalid, _) = api_test_request(
      port,
      path + "/reply",
      write,
      Some({ "discussion": id, "body": "Reply", "version": "1" }),
    )
    assert_eq(invalid, 400)
    let (missing, _) = api_test_request(
      port,
      path + "/reply",
      write,
      Some({ "discussion": "9223372036854775807", "body": "Reply" }),
    )
    assert_eq(missing, 404)
    let (replied, result) = api_test_request(
      port,
      path + "/reply",
      contributor_token,
      Some({ "discussion": id, "body": "First reply" }),
    )
    assert_eq(replied, 200)
    assert_true(
      result is { "discussion": { "reply_count": String("1"), .. }, .. },
    )
    let (resolved, result) = api_test_request(
      port,
      path + "/resolve-discussion",
      write,
      Some({ "discussion": id, "state_version": "1" }),
    )
    assert_eq(resolved, 200)
    assert_true(
      result
      is {
        "discussion": { "resolved": True, "state_version": String("2"), .. },
        ..
      },
    )
    let (stale, _) = api_test_request(
      port,
      path + "/reopen-discussion",
      write,
      Some({ "discussion": id, "state_version": "1" }),
    )
    assert_eq(stale, 400)
    let (_, result) = api_test_request(
      port,
      path + "/discussions?filter=unresolved",
      read,
      None,
    )
    assert_true(
      result is { "items": Array([]), "unresolved_count": String("0"), .. },
    )
    let route = "/alice/demo/merge-requests/1"
    let (_, html) = @web_testkit.http_get_path_with_cookie(port, route, cookie)
    assert_true(html.contains("0 unresolved"))
    assert_true(html.contains("Reopen discussion"))
    assert_true(html.contains("First reply"))
    let token = @web_testkit.extract_attr(
      html, "name=\"csrf_token\"", "value=\"",
    )
    let (csrf, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route + "/reply",
      "discussion=\{id}&body=Blocked",
      cookie,
    )
    assert_eq(csrf.code, 403)
    let (reopened, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route + "/reopen-discussion",
      "csrf_token=\{token}&discussion=\{id}&state_version=2",
      cookie,
    )
    assert_eq(reopened.code, 303)
    assert_true(
      reopened.headers
      .get("location")
      .unwrap_or("")
      .contains("discussion=" + id),
    )
    ignore(@test_support.merge_test_commit(dir, "threads", base, "second\n"))
    let latest = @collaboration.refresh_merge_request(pool, scope, dir, mr)
    assert_eq(latest.version, 2L)
    let (replied, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route + "/reply",
      "csrf_token=\{token}&discussion=\{id}&version=1&body=%3Cscript%3Eold%3C%2Fscript%3E",
      cookie,
    )
    assert_eq(replied.code, 303)
    let (_, html) = @web_testkit.http_get_path_with_cookie(
      port,
      route + "?discussion=" + id,
      cookie,
    )
    assert_true(html.contains("&lt;script&gt;old&lt;/script&gt;"))
    assert_false(html.contains("<script>old</script>"))
    assert_true(html.contains("Resolve discussion"))
    let (_, result) = api_test_request(
      port,
      path + "/discussions?discussion=" + id,
      read,
      None,
    )
    assert_true(
      result
      is {
        "discussion": {
          "version": String("1"),
          "state_version": String("3"),
          "reply_count": String("2"),
          ..
        },
        "has_more": False,
        ..
      },
    )
    let (invalid, _) = api_test_request(
      port,
      path + "/discussions?filter=bad",
      read,
      None,
    )
    assert_eq(invalid, 400)
    let (invalid, _) = api_test_request(
      port,
      path + "/discussions?discussion=" + id + "&page=0",
      read,
      None,
    )
    assert_eq(invalid, 400)
    let thread_id = @web_context.positive_resource_number(id)
    for i in 0..<49 {
      ignore(
        @collaboration.reply_merge_discussion(
          pool,
          scope,
          alice,
          latest,
          thread_id,
          "Page reply \{i}",
        ),
      )
    }
    let (replied, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route + "/reply",
      "csrf_token=\{token}&discussion=\{id}&body=Last%20page%20reply",
      cookie,
    )
    assert_eq(replied.code, 303)
    let location = replied.headers.get("location").unwrap_or("")
    assert_true(location.contains("discussion_page=2#comment-"))
    let (_, page_html) = @web_testkit.http_get_path_with_cookie(
      port,
      route + "?discussion=" + id + "&discussion_page=2",
      cookie,
    )
    assert_true(page_html.contains("Last page reply"))
    assert_true(page_html.contains("Previous page"))
    let (_, overview) = @web_testkit.http_get_path_with_cookie(
      port, route, cookie,
    )
    assert_true(overview.contains("View all 52 replies"))
    assert_true(overview.contains("discussion_page=2#comment-"))
    let (_, result) = api_test_request(
      port,
      path + "/discussions?discussion=" + id + "&page=2",
      read,
      None,
    )
    assert_true(
      result
      is {
        "discussion": { "replies": Array(replies), .. },
        "has_more": False,
        ..
      } &&
      replies.length() == 2,
    )
  })
}
