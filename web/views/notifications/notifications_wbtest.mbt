///|
async test "inbox requests enforce session CSRF recipient ownership and current repository access" {
  @web_testkit.with_repository_test_app((
    port,
    pool,
    root,
    alice_cookie,
    bob_cookie,
  ) => {
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id, user_id, role) VALUES (1, 2, 'member')",
        ),
      )
    })
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let git_dir = repo.git_dir(root)
    ignore(
      @test_support.merge_test_commit(
        git_dir,
        "review",
        @gitops.branch_sha(git_dir, "master"),
        "review\n",
      ),
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, git_dir, alice, "<script>Review</script>", "", "review", "master",
      false,
    )
    let (_, html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests/1", alice_cookie,
    )
    let csrf = @web_testkit.extract_attr(
      html, "action=\"/alice/demo/merge-requests/1/request-review\"", "value=\"",
    )
    let (no_token, _) = @web_testkit.http_post_path_with_cookie(
      port, "/alice/demo/merge-requests/1/request-review", "reviewer=2&version=1",
      alice_cookie,
    )
    assert_eq(no_token.code, 403)
    let (requested, body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/merge-requests/1/request-review",
      "csrf_token=\{csrf}&reviewer=2&version=1",
      alice_cookie,
    )
    assert_eq(requested.code, 303, msg=body)
    let (count, value) = @web_testkit.http_get_path_with_cookie(
      port, "/-/notifications/count", bob_cookie,
    )
    assert_eq(count.code, 200)
    assert_eq(value, "1")
    let (inbox, html) = @web_testkit.http_get_path_with_cookie(
      port, "/-/notifications", bob_cookie,
    )
    assert_eq(inbox.code, 200)
    assert_eq(inbox.headers.get("cache-control"), Some("no-store"))
    assert_true(html.contains("&lt;script&gt;Review&lt;/script&gt;"))
    assert_true(!html.contains("<script>Review</script>"))
    assert_true(html.contains("Review requested"))
    let token = @web_testkit.extract_attr(
      html, "name=\"csrf_token\"", "value=\"",
    )
    let item = @collaboration.inbox_items(pool, bob, "unread", 1L)[0]
    let (_, alice_inbox) = @web_testkit.http_get_path_with_cookie(
      port, "/-/notifications", alice_cookie,
    )
    let alice_token = @web_testkit.extract_attr(
      alice_inbox, "name=\"csrf_token\"", "value=\"",
    )
    let (wrong_user, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/notifications/\{item.id}/read",
      "csrf_token=\{alice_token}",
      alice_cookie,
    )
    assert_eq(wrong_user.code, 404)
    let (read, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/notifications/\{item.id}/read",
      "csrf_token=\{token}",
      bob_cookie,
    )
    assert_eq(read.code, 303)
    assert_eq(
      read.headers.get("location"),
      Some("/alice/demo/merge-requests/1?version=1"),
    )
    let (_, count) = @web_testkit.http_get_path_with_cookie(
      port, "/-/notifications/count", bob_cookie,
    )
    assert_eq(count, "0")
    let (_, pending) = @web_testkit.http_get_path_with_cookie(
      port, "/-/notifications?filter=reviews", bob_cookie,
    )
    assert_true(pending.contains("&lt;script&gt;Review&lt;/script&gt;"))
    let subscription = @collaboration.thread_subscription(
      pool,
      bob,
      scope,
      mr.id,
      false,
    )
    let (mute, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/notifications/threads/\{subscription.id}",
      "csrf_token=\{token}&subscribed=0",
      bob_cookie,
    )
    assert_eq(mute.code, 303)
    let (settings, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/notifications/settings",
      "csrf_token=\{token}&email=on",
      bob_cookie,
    )
    assert_eq(settings.code, 303)
    assert_true(@collaboration.notification_email_enabled(pool, bob))
    let (bad_filter, _) = @web_testkit.http_get_path_with_cookie(
      port, "/-/notifications?filter=invalid", bob_cookie,
    )
    assert_eq(bad_filter.code, 400)
    pool.with_client(client => {
      ignore(
        client.execute(
          "DELETE FROM team_member WHERE team_id = 1 AND user_id = 2",
        ),
      )
    })
    let (_, private) = @web_testkit.http_get_path_with_cookie(
      port, "/-/notifications?filter=all", bob_cookie,
    )
    assert_true(!private.contains("Review&lt;/script&gt;"))
    let (revoked, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/notifications/\{item.id}/read",
      "csrf_token=\{token}",
      bob_cookie,
    )
    assert_eq(revoked.code, 404)
    let (anonymous, _) = @web_testkit.http_get_path(port, "/-/notifications")
    assert_eq(anonymous.code, 303)
  })
}
