///|
async test "review requests are versioned idempotent and separate from the merge gate" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let bob = @identity.active_user_by_name(pool, "bob")
    let scope = @repository.repository_scope(pool, alice, repo)
    let git_dir = repo.git_dir(root)
    let base = @gitops.branch_sha(git_dir, "master")
    let first = @test_support.merge_test_commit(
      git_dir, "review", base, "first\n",
    )
    let mr = create_merge_request(
      pool, scope, git_dir, alice, "Review me", "", "review", "master", false,
    )
    for reviewer in [alice.id, bob.id] {
      try request_merge_review(pool, alice, scope, mr, reviewer, 1L) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted author or outsider as reviewer")
      }
    }
    request_merge_review(pool, alice, scope, mr, admin.id, 1L)
    request_merge_review(pool, alice, scope, mr, admin.id, 1L)
    assert_eq(inbox_items(pool, admin, "unread", 1L).length(), 1)
    assert_eq(inbox_items(pool, admin, "reviews", 1L).length(), 1)
    assert_eq(unread_notification_count(pool, alice), 0L)
    assert_eq(merge_review_counts(pool, scope, mr).0, 0L)
    submit_merge_review(pool, admin, mr, 1L, "comment", "A question")
    assert_eq(inbox_items(pool, admin, "reviews", 1L).length(), 1)
    submit_merge_review(pool, admin, mr, 1L, "changes_requested", "Please fix")
    assert_true(inbox_items(pool, admin, "reviews", 1L).is_empty())
    assert_true(
      inbox_items(pool, alice, "unread", 1L)
      .iter()
      .any(item => item.kind == "changes_requested"),
    )
    assert_eq(merge_review_counts(pool, scope, mr).1, 1L)
    request_merge_review(pool, alice, scope, mr, admin.id, 1L)
    assert_eq(merge_review_counts(pool, scope, mr).1, 1L)
    ignore(
      @test_support.merge_test_commit(git_dir, "review", first, "second\n"),
    )
    assert_true(refresh_next_requested_review(pool, root))
    assert_true(!refresh_next_requested_review(pool, root))
    let latest = require_merge_request(pool, scope, mr.number)
    assert_eq(latest.version, 2L)
    assert_eq(review_requests(pool, alice, scope, latest)[0].version, 2L)
    let count = unread_notification_count(pool, admin)
    ignore(refresh_merge_request(pool, scope, git_dir, latest))
    assert_eq(unread_notification_count(pool, admin), count)
    try request_merge_review(pool, alice, scope, latest, admin.id, 1L) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted stale request")
    }
    submit_merge_review(pool, admin, latest, 2L, "approved", "")
    assert_true(inbox_items(pool, admin, "reviews", 1L).is_empty())
    enqueue_merge(pool, scope, alice, latest, 2L)
    assert_true(run_next_merge_job(pool, root))
    assert_true(
      inbox_items(pool, admin, "unread", 1L)
      .iter()
      .any(item => item.kind == "merged"),
    )
    assert_true(!run_next_merge_job(pool, root))
    let items = inbox_items(pool, admin, "all", 1L)
    assert_eq(items.filter(item => item.kind == "merged").length(), 1)
  })
}

///|
async test "subscriptions mute ordinary activity but direct assignments still notify" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id, user_id, role) VALUES (1, 2, 'member')",
        ),
      )
    })
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let number = create_issue(pool, scope, alice, "Assigned", "", bob.id)
    let issue = require_issue(pool, scope, number)
    assert_eq(inbox_items(pool, bob, "assigned", 1L).length(), 1)
    assert_eq(inbox_items(pool, bob, "unread", 1L)[0].kind, "assigned")
    let subscription = thread_subscription(pool, bob, scope, issue.id, true)
    ignore(set_thread_subscription(pool, bob, subscription.id, false))
    let before = unread_notification_count(pool, bob)
    mutate_issue(
      pool, scope, alice, issue, 1L, "comment", "", "", 0L, "Muted reply",
    )
    assert_eq(unread_notification_count(pool, bob), before)
    mutate_issue(pool, scope, alice, issue, 1L, "edit", "Assigned", "", 0L, "")
    let issue = require_issue(pool, scope, number)
    mutate_issue(
      pool,
      scope,
      alice,
      issue,
      issue.edit_version,
      "edit",
      "Assigned",
      "",
      bob.id,
      "",
    )
    assert_eq(unread_notification_count(pool, bob), before + 1L)
    let issue = require_issue(pool, scope, number)
    mutate_issue(
      pool,
      scope,
      bob,
      issue,
      issue.edit_version,
      "comment",
      "",
      "",
      0L,
      "My reply",
    )
    assert_true(
      !thread_subscription(pool, bob, scope, issue.id, true).subscribed,
    )
    assert_eq(unread_notification_count(pool, bob), before + 1L)
    let item = inbox_items(pool, bob, "unread", 1L)[0]
    try mark_notification_read(pool, alice, item.id) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("read someone else's notification")
    }
    ignore(mark_notification_read(pool, bob, item.id))
    assert_eq(unread_notification_count(pool, bob), before)
    mark_all_notifications_read(pool, bob, item.id)
    assert_eq(unread_notification_count(pool, bob), 0L)
    assert_eq(inbox_items(pool, bob, "assigned", 1L).length(), 1)
    pool.with_client(client => {
      ignore(
        client.execute(
          "DELETE FROM team_member WHERE team_id = 1 AND user_id = 2",
        ),
      )
    })
    assert_true(inbox_items(pool, bob, "all", 1L).is_empty())
    assert_true(inbox_items(pool, bob, "assigned", 1L).is_empty())
    try set_thread_subscription(pool, bob, subscription.id, true) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("subscribed after access revocation")
    }
  })
}

///|
async test "notification transaction rollback pagination and read watermark" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let number = create_issue(pool, scope, alice, "Pagination", "", 0L)
    let issue = require_issue(pool, scope, number)
    let thread = thread_subscription(pool, admin, scope, issue.id, true)
    ignore(set_thread_subscription(pool, admin, thread.id, true))
    for i in 0..<55 {
      mutate_issue(
        pool,
        scope,
        alice,
        issue,
        1L,
        "comment",
        "",
        "",
        0L,
        "Reply \{i}",
      )
    }
    let first = inbox_items(pool, admin, "unread", 1L)
    assert_eq(first.length(), 51)
    assert_eq(inbox_items(pool, admin, "unread", 2L).length(), 5)
    let watermark = first[0].id
    mutate_issue(
      pool, scope, alice, issue, 1L, "comment", "", "", 0L, "New arrival",
    )
    mark_all_notifications_read(pool, admin, watermark)
    assert_eq(unread_notification_count(pool, admin), 1L)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|CREATE TEMP TRIGGER reject_notifications BEFORE INSERT ON collaboration_notification BEGIN
          #|SELECT RAISE(ABORT, 'test rollback'); END;
        ),
      )
    })
    let before = list_issue_activity(pool, issue, 1L).length()
    try
      mutate_issue(
        pool, scope, alice, issue, 1L, "comment", "", "", 0L, "Rollback",
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("notification failure did not roll back")
    }
    assert_eq(list_issue_activity(pool, issue, 1L).length(), before)
    assert_eq(unread_notification_count(pool, admin), 1L)
    pool.with_client(client => {
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "check notifications are current deduplicated and never replay obsolete results" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let git_dir = scope.repo.git_dir(root)
    let first = @test_support.merge_test_commit(
      git_dir,
      "checks",
      @gitops.branch_sha(git_dir, "master"),
      "checks\n",
    )
    let mr = create_merge_request(
      pool, scope, git_dir, alice, "Checks", "", "checks", "master", false,
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO merge_check(merge_request_id, version, generation, workflow_path) VALUES (?, 1, 1, '.github/workflows/check.yml')",
          params=[mr.id],
        ),
      )
    })
    assert_eq(
      inbox_items(pool, alice, "unread", 1L)[0].kind,
      "checks_awaiting_approval",
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE merge_check SET state = 'completed', conclusion = 'failure'",
        ),
      )
      ignore(
        client.execute(
          "UPDATE merge_check SET state = 'completed', conclusion = 'failure'",
        ),
      )
    })
    assert_eq(
      inbox_items(pool, alice, "unread", 1L)
      .filter(item => item.kind == "checks_failed")
      .length(),
      1,
    )
    ignore(
      @test_support.merge_test_commit(git_dir, "checks", first, "new checks\n"),
    )
    ignore(refresh_merge_request(pool, scope, git_dir, mr))
    let before = unread_notification_count(pool, alice)
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE merge_check SET state = 'completed', conclusion = 'timed_out'",
        ),
      )
    })
    assert_eq(unread_notification_count(pool, alice), before)
  })
}

///|
async test "an administrator requesting review participates in the subsequent discussion" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let bob = @identity.active_user_by_name(pool, "bob")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id, user_id, role) VALUES (1, 2, 'member')",
        ),
      )
    })
    let git_dir = scope.repo.git_dir(root)
    ignore(
      @test_support.merge_test_commit(
        git_dir,
        "manager-review",
        @gitops.branch_sha(git_dir, "master"),
        "review\n",
      ),
    )
    let mr = create_merge_request(
      pool, scope, git_dir, alice, "Delegated review", "", "manager-review", "master",
      false,
    )
    request_merge_review(pool, alice, scope, mr, bob.id, 1L)
    submit_merge_review(pool, bob, mr, 1L, "approved", "First review")
    assert_true(
      !thread_subscription(pool, admin, scope, mr.id, false).subscribed,
    )
    request_merge_review(pool, admin, scope, mr, bob.id, 1L)
    assert_true(
      thread_subscription(pool, admin, scope, mr.id, false).subscribed,
    )
    assert_eq(unread_notification_count(pool, admin), 0L)
    submit_merge_review(pool, bob, mr, 1L, "approved", "Reviewed")
    assert_eq(inbox_items(pool, admin, "unread", 1L)[0].kind, "approved")
    assert_eq(inbox_items(pool, alice, "unread", 1L)[0].kind, "approved")
  })
}
