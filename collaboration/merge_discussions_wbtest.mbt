///|
async test "discussion lifecycle preserves old revisions replies reviews and subscriptions" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let bob = @identity.active_user_by_name(pool, "bob")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let dir = repo.git_dir(root)
    let base = @gitops.branch_sha(dir, "master")
    ignore(@test_support.merge_test_commit(dir, "discussions", base, "first\n"))
    let mr = create_merge_request(
      pool, scope, dir, alice, "Discussions", "", "discussions", "master", false,
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id, user_id, role) VALUES (?, ?, 'member')",
          params=[scope.team_id, bob.id],
        ),
      )
    })
    submit_merge_review(
      pool, admin, mr, 1L, "changes_requested", "Please fix this",
    )
    let discussion = list_merge_discussions(pool, scope, alice, mr, 1L)[0]
    assert_eq(discussion.id, discussion.root.id)
    assert_eq(discussion.state_version, 1L)
    assert_false(discussion.resolved)
    assert_true(discussion.can_resolve)
    assert_false(
      merge_discussion(pool, scope, bob, mr, discussion.id).can_resolve,
    )
    try
      set_merge_discussion_resolved(
        pool,
        scope,
        bob,
        mr,
        discussion.id,
        1L,
        true,
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("unrelated contributor resolved discussion")
    }
    ignore(
      set_thread_subscription(
        pool,
        alice,
        thread_subscription(pool, alice, scope, mr.id, false).id,
        false,
      ),
    )
    let watermark = inbox_items(pool, alice, "all", 1L)
      .get(0)
      .map(item => item.id)
      .unwrap_or(0L)
    let reply = reply_merge_discussion(
      pool,
      scope,
      bob,
      mr,
      discussion.id,
      "Fixed",
    )
    assert_true(reply > discussion.id)
    assert_true(thread_subscription(pool, bob, scope, mr.id, false).subscribed)
    assert_false(
      inbox_items(pool, alice, "all", 1L).any(item => item.id > watermark),
    )
    ignore(
      set_thread_subscription(
        pool,
        alice,
        thread_subscription(pool, alice, scope, mr.id, false).id,
        true,
      ),
    )
    set_merge_discussion_resolved(
      pool,
      scope,
      admin,
      mr,
      discussion.id,
      1L,
      true,
    )
    let resolved = merge_discussion(pool, scope, alice, mr, discussion.id)
    assert_true(resolved.resolved)
    assert_eq(resolved.state_version, 2L)
    assert_true(!resolved.state_actor.is_empty())
    assert_true(!resolved.state_changed_at.is_empty())
    assert_eq(unresolved_merge_discussions(pool, scope, alice, mr), 0L)
    assert_eq(merge_review_counts(pool, scope, mr).1, 1L)
    assert_true(
      inbox_items(pool, alice, "all", 1L).any(item => {
        item.kind == "discussion_resolved"
      }),
    )
    try
      set_merge_discussion_resolved(
        pool,
        scope,
        alice,
        mr,
        discussion.id,
        1L,
        false,
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale state version accepted")
    }
    set_merge_discussion_resolved(
      pool,
      scope,
      alice,
      mr,
      discussion.id,
      2L,
      true,
    )
    assert_eq(
      merge_discussion(pool, scope, alice, mr, discussion.id).state_version,
      2L,
    )
    ignore(
      reply_merge_discussion(pool, scope, alice, mr, discussion.id, "Thanks"),
    )
    assert_true(
      merge_discussion(pool, scope, alice, mr, discussion.id).resolved,
    )
    assert_eq(
      list_merge_discussions(pool, scope, alice, mr, 1L, filter="resolved").length(),
      1,
    )
    assert_true(
      list_merge_discussions(pool, scope, alice, mr, 1L, filter="unresolved").is_empty(),
    )
    set_merge_discussion_resolved(
      pool,
      scope,
      alice,
      mr,
      discussion.id,
      2L,
      false,
    )
    assert_eq(
      merge_discussion(pool, scope, alice, mr, discussion.id).state_version,
      3L,
    )
    assert_eq(unresolved_merge_discussions(pool, scope, alice, mr), 1L)
    assert_true(
      inbox_items(pool, admin, "all", 1L).any(item => {
        item.kind == "discussion_reopened"
      }),
    )
    ignore(
      @test_support.merge_test_commit(dir, "discussions", base, "second\n"),
    )
    let latest = refresh_merge_request(pool, scope, dir, mr)
    assert_eq(latest.version, 2L)
    ignore(
      reply_merge_discussion(
        pool,
        scope,
        bob,
        latest,
        discussion.id,
        "Old version reply",
      ),
    )
    let old = merge_discussion(pool, scope, alice, latest, discussion.id)
    assert_eq(old.replies.last().unwrap().version, 1L)
    assert_eq(old.reply_count, 3L)
    assert_eq(latest.edit_version, mr.edit_version)
    // A deleted root remains a stable discussion; deleting replies preserves their place.
    submit_merge_review(pool, alice, latest, 2L, "comment", "Root comment")
    let plain = list_merge_discussions(pool, scope, alice, latest, 1L)[0]
    let reply = reply_merge_discussion(
      pool,
      scope,
      bob,
      latest,
      plain.id,
      "Survives deletion",
    )
    set_merge_comment_deleted(pool, scope, alice, latest, plain.id, 2L, true)
    assert_eq(
      merge_discussion(pool, scope, alice, latest, plain.id).root.body,
      "",
    )
    assert_eq(
      merge_discussion(pool, scope, alice, latest, plain.id).replies[0].body,
      "Survives deletion",
    )
    set_merge_comment_deleted(pool, scope, bob, latest, reply, 2L, true)
    assert_eq(
      merge_discussion(pool, scope, alice, latest, plain.id).replies[0].kind,
      "comment_deleted",
    )
    set_merge_comment_deleted(pool, scope, alice, latest, plain.id, 2L, false)
    assert_eq(
      merge_discussion(pool, scope, alice, latest, plain.id).root.body,
      "Root comment",
    )
    edit_merge_request(pool, scope, alice, latest, "close", "", "")
    let closed = require_merge_request(pool, scope, mr.number)
    ignore(
      reply_merge_discussion(
        pool,
        scope,
        bob,
        closed,
        discussion.id,
        "Closed MR reply",
      ),
    )
    set_merge_discussion_resolved(
      pool,
      scope,
      alice,
      closed,
      discussion.id,
      3L,
      true,
    )
    assert_true(
      merge_discussion(pool, scope, alice, closed, discussion.id).resolved,
    )
  })
}

///|
async test "discussions reject cross MR access invalid bodies and bound pagination" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let dir = repo.git_dir(root)
    let base = @gitops.branch_sha(dir, "master")
    ignore(@test_support.merge_test_commit(dir, "one", base, "one\n"))
    ignore(@test_support.merge_test_commit(dir, "two", base, "two\n"))
    let one = create_merge_request(
      pool, scope, dir, alice, "One", "", "one", "master", false,
    )
    let two = create_merge_request(
      pool, scope, dir, alice, "Two", "", "two", "master", false,
    )
    submit_merge_review(pool, alice, one, 1L, "comment", "Start")
    let id = list_merge_discussions(pool, scope, alice, one, 1L)[0].id
    try
      ignore(reply_merge_discussion(pool, scope, bob, one, id, "Denied"))
    catch {
      @domain.NotFound(_) | @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("non contributor reply accepted")
    }
    for body in ["", "   ", "x".repeat(20001)] {
      try
        ignore(reply_merge_discussion(pool, scope, alice, one, id, body))
      catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("invalid reply accepted")
      }
    }
    try
      ignore(reply_merge_discussion(pool, scope, alice, two, id, "Cross MR"))
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("cross MR reply accepted")
    }
    try
      set_merge_discussion_resolved(pool, scope, alice, two, id, 1L, true)
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("cross MR resolve accepted")
    }
    for i in 0..<55 {
      ignore(reply_merge_discussion(pool, scope, alice, one, id, "Reply \{i}"))
    }
    let overview = list_merge_discussions(pool, scope, alice, one, 1L)[0]
    assert_eq(overview.replies.length(), 3)
    assert_eq(overview.replies[0].body, "Reply 52")
    let first = merge_discussion(pool, scope, alice, one, id)
    let second = merge_discussion(pool, scope, alice, one, id, page=2L)
    assert_eq(first.replies.length(), 50)
    assert_eq(first.replies[0].body, "Reply 0")
    assert_eq(second.replies.length(), 5)
    assert_eq(second.replies[0].body, "Reply 50")
    assert_eq(second.replies[4].body, "Reply 54")
    for i in 0..<51 {
      submit_merge_review(pool, alice, one, 1L, "comment", "Thread \{i}")
    }
    assert_eq(list_merge_discussions(pool, scope, alice, one, 1L).length(), 51)
    assert_eq(list_merge_discussions(pool, scope, alice, one, 2L).length(), 2)
    try
      ignore(list_merge_discussions(pool, scope, alice, one, 1L, filter="bad"))
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("invalid filter accepted")
    }
    pool.with_client(client => {
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "discussion notifications preserve exact targets across paging and deletion" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let dir = repo.git_dir(root)
    ignore(
      @test_support.merge_test_commit(
        dir,
        "targets",
        @gitops.branch_sha(dir, "master"),
        "targets\n",
      ),
    )
    let mr = create_merge_request(
      pool, scope, dir, alice, "Targets", "", "targets", "master", false,
    )
    submit_merge_review(pool, admin, mr, 1L, "comment", "Original root")
    let id = list_merge_discussions(pool, scope, alice, mr, 1L)[0].id
    let root_event = inbox_items(pool, alice, "all", 1L)[0]
    assert_eq(root_event.discussion_id, Some(id))
    assert_eq(root_event.comment_id, Some(id))
    for _ in 0..<51 {
      submit_merge_review(pool, alice, mr, 1L, "comment", "Newer root")
    }
    for i in 0..<51 {
      ignore(reply_merge_discussion(pool, scope, admin, mr, id, "Reply \{i}"))
    }
    let event = inbox_items(pool, alice, "all", 1L)[0]
    let comment = event.comment_id.unwrap()
    assert_eq(event.discussion_id, Some(id))
    assert_true(
      event
      .url()
      .contains(
        "discussion=" + id.to_string() + "&comment=" + comment.to_string(),
      ),
    )
    assert_true(event.url().has_suffix("#comment-" + comment.to_string()))
    assert_eq(
      merge_discussion_comment_page(pool, scope, alice, mr, id, comment),
      2L,
    )
    set_merge_comment_deleted(pool, scope, admin, mr, comment, 1L, true)
    assert_eq(
      merge_discussion_comment_page(pool, scope, alice, mr, id, comment),
      2L,
    )
    set_merge_comment_deleted(pool, scope, admin, mr, comment, 1L, false)
    set_merge_discussion_resolved(pool, scope, admin, mr, id, 1L, true)
    let state = inbox_items(pool, alice, "all", 1L)[0]
    assert_eq(state.kind, "discussion_resolved")
    assert_eq(state.discussion_id, Some(id))
    assert_eq(state.comment_id, None)
    assert_true(
      state
      .url()
      .has_suffix(
        "?discussion=" + id.to_string() + "#discussion-" + id.to_string(),
      ),
    )
    let group = inbox_groups(pool, alice, "all", 1L)[0]
    assert_eq(group.url(), "/alice/demo/merge-requests/1")
    assert_true(group.events[0].url().contains("discussion="))
    let newer = list_merge_discussions(pool, scope, alice, mr, 1L)[0].id
    try
      ignore(
        merge_discussion_comment_page(pool, scope, alice, mr, newer, comment),
      )
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("cross discussion comment target accepted")
    }
    pool.with_client(client => {
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
