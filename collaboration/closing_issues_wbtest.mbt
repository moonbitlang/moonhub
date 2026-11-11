///|
test "closing keywords parse canonical local issue numbers and deduplicate clauses" {
  assert_eq(
    closing_issue_numbers(
      "Closes #1, #2 and #3. FIXES: #2; resolved #4\nClose #5, and #6\nfixed #7 #8; resolve #9; closed #10; fix #11; resolves #12",
    ),
    [1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, 10L, 11L, 12L],
  )
  assert_eq(
    closing_issue_numbers(
      "修复完成。 Closes #9223372036854775807\nCloses #1, #1",
    ),
    [9223372036854775807L, 1L],
  )
  assert_eq(closing_issue_numbers("Closes #1, references #2"), [1L])
}

///|
test "closing keywords ignore malformed foreign and ordinary references" {
  for
    text in [
      "#1", "Related #1", "Discloses #1", "prefix_Fixes #1", "1Fixes #1", "Closes#1",
      "Closes #0", "Closes #01", "Closes #-1", "Closes #9223372036854775808", "Closes #1abc",
      "Closes #1/path", "Closes #1-2", "Closes #1_2", "Closes #1#2", "Closes owner/repo#1",
      "Closes https://example.com/issues/1", "Closes !1", "Closes\n#1", "\\Closes #1",
      "Closes \\#1",
    ] {
    assert_eq(closing_issue_numbers(text), [], msg=text)
  }
}

///|
test "closing keywords ignore Markdown examples quotes and HTML comments" {
  assert_eq(
    closing_issue_numbers(
      "`Closes #1` and ``Fixes #2``\n```md\nCloses #3\n```\n~~~\nFixes #4\n~~~\n    Closes #5\n\tFixes #6\n> Closes #7\n<!-- Closes #8\nFixes #9 --> Resolves #10\nCloses #11",
    ),
    [10L, 11L],
  )
  assert_eq(closing_issue_numbers("````\n```\nCloses #1\n````\nFixes #2"), [2L])
  assert_eq(closing_issue_numbers("`code\nCloses #1` Fixes #2"), [2L])
}

///|
async test "successful merge closes declared issues with activity versions and notifications" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let other = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "public",
    })
    let first = create_issue(pool, scope, alice, "First", "", 0L)
    let second = create_issue(pool, scope, alice, "Second", "", 0L)
    let closed = create_issue(pool, scope, alice, "Already closed", "", 0L)
    let linked = create_issue(pool, scope, alice, "Related only", "", 0L)
    let foreign = create_issue(pool, other, alice, "Other repository", "", 0L)
    let issue = require_issue(pool, scope, closed)
    mutate_issue(
      pool,
      scope,
      alice,
      issue,
      issue.edit_version,
      "close",
      "",
      "",
      0L,
      "",
    )
    let dir = repo.git_dir(root)
    ignore(
      @test_support.merge_test_commit(
        dir,
        "close-issues",
        @gitops.branch_sha(dir, "master"),
        "fix\n",
      ),
    )
    let mr = create_merge_request(
      pool,
      scope,
      dir,
      alice,
      "Fix tracked work",
      "Closes #\{first}, #\{second}. Fixes #\{first}. Resolves #\{closed}. Closes #99999",
      "close-issues",
      "master",
      false,
      issue=linked,
    )
    assert_eq(require_issue(pool, scope, first).status, "open")
    enqueue_merge(pool, scope, admin, mr, mr.version)
    assert_eq(require_issue(pool, scope, first).status, "open")
    assert_true(run_next_merge_job(pool, root))
    let merged = require_merge_request(pool, scope, mr.number)
    assert_eq(merged.status, "merged", msg=merged.job_error)
    for number in [first, second] {
      let issue = require_issue(pool, scope, number)
      assert_eq(issue.status, "closed")
      assert_eq(issue.edit_version, 2L)
      let activity = list_issue_activity(pool, issue, 1L).filter(item => {
        item.kind == "close"
      })
      assert_eq(activity.length(), 1)
      assert_eq(activity[0].actor, admin.display_name)
      assert_eq(activity[0].body, "Closed by merge request !\{mr.number}.")
    }
    assert_eq(require_issue(pool, scope, closed).edit_version, 2L)
    assert_eq(require_issue(pool, scope, linked).status, "open")
    assert_eq(require_issue(pool, other, foreign).status, "open")
    assert_eq(
      inbox_items(pool, alice, "all", 1L)
      .filter(item => item.kind == "close")
      .length(),
      2,
    )
    // A repeated completion, even after reopening, must not close or notify twice.
    let issue = require_issue(pool, scope, first)
    mutate_issue(
      pool,
      scope,
      alice,
      issue,
      issue.edit_version,
      "reopen",
      "",
      "",
      0L,
      "",
    )
    finish_merge(pool, merged, admin.id, merged.merged_sha)
    assert_eq(require_issue(pool, scope, first).status, "open")
    assert_eq(require_issue(pool, scope, second).edit_version, 2L)
    assert_false(run_next_merge_job(pool, root))
  })
}

///|
async test "MR edits replace closing directives and failed or closed MRs leave issues open" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let original = create_issue(pool, scope, alice, "Original", "", 0L)
    let replacement = create_issue(pool, scope, alice, "Replacement", "", 0L)
    let dir = repo.git_dir(root)
    let base = @gitops.branch_sha(dir, "master")
    let source = @test_support.merge_test_commit(dir, "fix", base, "fix\n")
    let mr = create_merge_request(
      pool,
      scope,
      dir,
      alice,
      "Fixes #\{original}",
      "Closes #\{original}",
      "fix",
      "master",
      false,
    )
    edit_merge_request(pool, scope, alice, mr, "close", "", "")
    assert_eq(require_issue(pool, scope, original).status, "open")
    edit_merge_request(
      pool,
      scope,
      alice,
      require_merge_request(pool, scope, mr.number),
      "reopen",
      "",
      "",
    )
    let current = require_merge_request(pool, scope, mr.number)
    edit_merge_request(
      pool,
      scope,
      alice,
      current,
      "edit",
      current.title,
      "Fixes #\{replacement}",
    )
    let current = require_merge_request(pool, scope, mr.number)
    enqueue_merge(pool, scope, alice, current, current.version)
    ignore(@test_support.merge_test_commit(dir, "fix", source, "changed\n"))
    assert_true(run_next_merge_job(pool, root))
    assert_eq(
      require_merge_request(pool, scope, mr.number).job_status,
      "failed",
    )
    assert_eq(require_issue(pool, scope, original).status, "open")
    assert_eq(require_issue(pool, scope, replacement).status, "open")
    let current = refresh_merge_request(
      pool,
      scope,
      dir,
      require_merge_request(pool, scope, mr.number),
    )
    enqueue_merge(pool, scope, alice, current, current.version)
    assert_true(run_next_merge_job(pool, root))
    assert_eq(require_issue(pool, scope, original).status, "open")
    assert_eq(require_issue(pool, scope, replacement).status, "closed")
  })
}

///|
async test "issue closure rolls back with merge finalization and recovery completes it once" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let number = create_issue(pool, scope, alice, "Recover", "", 0L)
    let dir = repo.git_dir(root)
    let base = @gitops.branch_sha(dir, "master")
    ignore(@test_support.merge_test_commit(dir, "recovery", base, "fix\n"))
    let mr = create_merge_request(
      pool,
      scope,
      dir,
      alice,
      "Recover",
      "Closes #\{number}",
      "recovery",
      "master",
      false,
    )
    enqueue_merge(pool, scope, alice, mr, mr.version)
    pool.with_client(client => {
      ignore(
        client.execute(
          "CREATE TRIGGER reject_issue_close BEFORE INSERT ON issue_activity WHEN NEW.kind = 'close' BEGIN SELECT RAISE(ABORT, 'test closure failure'); END",
        ),
      )
    })
    try run_next_merge_job(pool, root) catch {
      _ => ()
    } noraise {
      _ => fail("closure failure did not abort finalization")
    }
    assert_eq(require_merge_request(pool, scope, mr.number).status, "open")
    assert_eq(require_issue(pool, scope, number).status, "open")
    assert_eq(require_issue(pool, scope, number).edit_version, 1L)
    assert_true(@gitops.branch_sha(dir, "master") != base)
    pool.with_client(client => {
      ignore(client.execute("DROP TRIGGER reject_issue_close"))
    })
    assert_true(run_next_merge_job(pool, root))
    assert_eq(require_merge_request(pool, scope, mr.number).status, "merged")
    let issue = require_issue(pool, scope, number)
    assert_eq(issue.status, "closed")
    assert_eq(issue.edit_version, 2L)
    assert_eq(
      list_issue_activity(pool, issue, 1L)
      .filter(item => item.kind == "close")
      .length(),
      1,
    )
    assert_false(run_next_merge_job(pool, root))
  })
}
