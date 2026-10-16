///|
async test "MR API preserves omitted metadata and deletes only authorized plain comments" {
  @web_testkit.with_repository_test_app((port, pool, root, alice_cookie, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let bob = @identity.active_user_by_name(pool, "bob")
    let write = @identity.create_access_token(pool, alice, "author", "write", 1)
    let read = @identity.create_access_token(pool, alice, "read", "read", 1)
    let reviewer = @identity.create_access_token(
      pool, admin, "reviewer", "write", 1,
    )
    let contributor_token = @identity.create_access_token(
      pool, bob, "member", "write", 1,
    )
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let dir = repo.git_dir(root)
    let base = @gitops.branch_sha(dir, "master")
    ignore(@test_support.merge_test_commit(dir, "metadata", base, "metadata\n"))
    let (status, _) = api_test_request(
      port,
      "/repos/alice/demo/mrs",
      write,
      Some({
        "title": "Original",
        "description": "Keep me",
        "source": "metadata",
        "target": "master",
      }),
    )
    assert_eq(status, 200)
    let path = "/repos/alice/demo/mrs/1"
    let initial = @collaboration.require_merge_request(pool, scope, 1L)
    @collaboration.submit_merge_review(
      pool, admin, initial, 1L, "approved", "Reviewed",
    )
    let initial_generation : Int64 = pool.with_client(client => {
      client
      .query_one("SELECT check_generation FROM merge_request WHERE id = ?", params=[
        initial.id,
      ])
      .get_name("check_generation")
    })
    let (unknown, _) = api_test_request(
      port,
      path + "/edit",
      write,
      Some({ "edit_version": "1", "title": "Bad", "decision": "approved" }),
    )
    assert_eq(unknown, 400)
    let (denied, _) = api_test_request(
      port,
      path + "/edit",
      read,
      Some({ "edit_version": "1", "title": "Denied" }),
    )
    assert_eq(denied, 403)
    let (empty, _) = api_test_request(
      port,
      path + "/edit",
      write,
      Some({ "edit_version": "1" }),
    )
    assert_eq(empty, 400)
    let (edited, result) = api_test_request(
      port,
      path + "/edit",
      write,
      Some({ "edit_version": "1", "title": "English title" }),
    )
    assert_eq(edited, 200)
    assert_true(
      result
      is {
        "title": String("English title"),
        "description": String("Keep me"),
        "edit_version": String("2"),
        "version": String("1"),
        ..
      },
    )
    let (stale, _) = api_test_request(
      port,
      path + "/edit",
      write,
      Some({ "edit_version": "1", "title": "Stale" }),
    )
    assert_eq(stale, 400)
    let (invalid, _) = api_test_request(
      port,
      path + "/edit",
      write,
      Some({ "edit_version": "2", "title": " " }),
    )
    assert_eq(invalid, 400)
    let (cleared, result) = api_test_request(
      port,
      path + "/edit",
      write,
      Some({ "edit_version": "2", "description": "" }),
    )
    assert_eq(cleared, 200)
    assert_true(
      result
      is {
        "title": String("English title"),
        "description": String(""),
        "edit_version": String("3"),
        ..
      },
    )
    let latest = @collaboration.require_merge_request(pool, scope, 1L)
    assert_eq(@collaboration.merge_review_counts(pool, scope, latest).0, 1L)
    assert_eq(latest.version, initial.version)
    pool.with_client(client => {
      let generation : Int64 = client
        .query_one("SELECT check_generation FROM merge_request WHERE id = ?", params=[
          initial.id,
        ])
        .get_name("check_generation")
      assert_eq(generation, initial_generation)
    })
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id, user_id, role) VALUES (?, ?, 'member')",
          params=[scope.team_id, bob.id],
        ),
      )
    })
    let (forbidden, _) = api_test_request(
      port,
      path + "/edit",
      contributor_token,
      Some({ "edit_version": "3", "title": "Unauthorized" }),
    )
    assert_eq(forbidden, 403)
    let (commented, _) = api_test_request(
      port,
      path + "/comment",
      contributor_token,
      Some({ "version": "1", "body": "Duplicate review" }),
    )
    assert_eq(commented, 200)
    let mr = @collaboration.require_merge_request(pool, scope, 1L)
    let id = @collaboration.list_merge_activity(pool, mr, 1L)[0].id.to_string()
    let (_, detail) = api_test_request(port, path, write, None)
    guard detail is { "activity": Array(items), .. } else {
      fail("activity missing")
    }
    assert_true(
      items[0] is { "id": String(comment_id), "actor_id": String(actor_id), .. } &&
      comment_id == id &&
      actor_id == bob.id.to_string(),
    )
    let (denied, _) = api_test_request(
      port,
      path + "/delete-comment",
      read,
      Some({ "version": "1", "comment": id }),
    )
    assert_eq(denied, 403)
    let (stale, _) = api_test_request(
      port,
      path + "/delete-comment",
      contributor_token,
      Some({ "version": "2", "comment": id }),
    )
    assert_eq(stale, 400)
    let (deleted, _) = api_test_request(
      port,
      path + "/delete-comment",
      contributor_token,
      Some({ "version": "1", "comment": id }),
    )
    assert_eq(deleted, 200)
    let (_, detail) = api_test_request(port, path, read, None)
    assert_true(!detail.stringify().contains("Duplicate review"))
    let (_, html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests/1", alice_cookie,
    )
    assert_true(!html.contains("Duplicate review"))
    let (restored, _) = api_test_request(
      port,
      path + "/restore-comment",
      reviewer,
      Some({ "version": "1", "comment": id }),
    )
    assert_eq(restored, 200)
    let (_, detail) = api_test_request(port, path, read, None)
    assert_true(detail.stringify().contains("Duplicate review"))
    let (missing, _) = api_test_request(
      port,
      path + "/delete-comment",
      write,
      Some({ "version": "1", "comment": "9223372036854775807" }),
    )
    assert_eq(missing, 404)
  })
}
