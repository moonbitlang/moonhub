///|
async test "issue queries keep repository scope literal search and page boundaries" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let other = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "public",
    })
    for i = 1; i <= 52; i = i + 1 {
      ignore(create_issue(pool, scope, alice, "Issue \{i}", "", alice.id))
    }
    ignore(create_issue(pool, other, alice, "Other repository", "", 0L))
    let first = list_issues(pool, scope, "open", 1L, false, alice.id, "")
    assert_eq(first.length(), 51)
    assert_eq(first[0].number, 52L)
    assert_eq(first[50].number, 2L)
    let second = list_issues(pool, scope, "open", 2L, true, alice.id, "")
    assert_eq(second.length(), 2)
    assert_eq(second[0].number, 2L)
    assert_eq(second[1].number, 1L)
    assert_eq(
      list_issues(pool, other, "open", 1L, false, alice.id, "").length(),
      1,
    )
    assert_true(
      list_issues(pool, scope, "open", 1L, false, alice.id, "%").is_empty(),
    )
    assert_true(
      list_issues(pool, scope, "closed", 1L, false, alice.id, "").is_empty(),
    )
    assert_eq(
      list_issues(pool, scope, "open", 1L, false, alice.id, "ISSUE 52").length(),
      1,
    )
    let issue = require_issue(pool, scope, 1L)
    mutate_issue(
      pool,
      scope,
      alice,
      issue,
      issue.edit_version,
      "comment",
      "",
      "",
      0L,
      "Details",
    )
    let activity = list_issue_activity(pool, issue, 1L)
    assert_eq(activity[0].actor, "Alice")
    assert_eq(activity[0].body, "Details")
    assert_eq(issue_assignees(pool, scope)[0].name_key, "alice")
    assert_true(issue_merge_requests(pool, scope, issue).is_empty())
    assert_true(list_merge_requests(pool, scope, "open", 1L).is_empty())
    assert_true(branch_rules(pool, scope).is_empty())
  })
}
