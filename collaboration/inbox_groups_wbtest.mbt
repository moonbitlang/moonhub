///|
async test "inbox groups before pagination and marks only the submitted visible thread boundary" {
  @test_support.with_repository_test_data((pool, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id, user_id, role) VALUES (?, ?, 'member')",
          params=[scope.team_id, admin.id],
        ),
      )
    })
    let first = create_issue(pool, scope, alice, "First", "", admin.id)
    let second = create_issue(pool, scope, alice, "Second", "", admin.id)
    for _ in 0..<60 {
      let issue = require_issue(pool, scope, first)
      mutate_issue(
        pool,
        scope,
        alice,
        issue,
        issue.edit_version,
        "comment",
        issue.title,
        issue.description,
        issue.assignee_id,
        "New update",
      )
    }
    let groups = inbox_groups(pool, admin, "unread", 1L)
    assert_eq(groups.length(), 2)
    assert_eq(groups[0].item.number, first)
    assert_eq(groups[1].item.number, second)
    assert_eq(groups[0].events.length(), 10)
    assert_true(groups[0].unread > 50L)
    let watermark = groups[0].item.id
    let issue = require_issue(pool, scope, first)
    mutate_issue(
      pool,
      scope,
      alice,
      issue,
      issue.edit_version,
      "close",
      issue.title,
      issue.description,
      issue.assignee_id,
      "",
    )
    mark_thread_notifications_read(
      pool,
      admin,
      groups[0].item.thread_id,
      watermark,
    )
    let remaining = inbox_groups(pool, admin, "unread", 1L)
    assert_eq(remaining.length(), 2)
    assert_eq(remaining[0].status, "closed")
    assert_eq(remaining[0].unread, 1L)
    assert_true(remaining[1].unread > 0L)
    let bob = @identity.active_user_by_name(pool, "bob")
    assert_true(inbox_groups(pool, bob, "all", 1L).is_empty())
    try
      mark_thread_notifications_read(
        pool,
        bob,
        groups[0].item.thread_id,
        watermark,
      )
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("marked another recipient's thread")
    }
  })
}
