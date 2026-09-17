///|
async test "issues preserve authors assignees and reject stale edits" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let admin = @identity.active_user_by_name(pool, "admin")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let number = create_issue(
      pool,
      scope,
      alice,
      "A real issue",
      "Description",
      alice.id,
    )
    assert_eq(number, 1L)
    let issue = require_issue(pool, scope, number)
    assert_eq(issue.author_id, alice.id)
    assert_eq(issue.assignee_id, alice.id)
    try
      mutate_issue(pool, scope, bob, issue, 1L, "edit", "Hijack", "", 0L, "")
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("nonmember edited an issue")
    }
    mutate_issue(
      pool, scope, admin, issue, 1L, "edit", "Updated", "New description", 0L, "",
    )
    let latest = require_issue(pool, scope, number)
    assert_eq(latest.edit_version, 2L)
    assert_eq(latest.title, "Updated")
    assert_eq(latest.author_id, alice.id)
    assert_eq(latest.assignee_id, 0L)
    try
      mutate_issue(pool, scope, alice, latest, 1L, "edit", "Stale", "", 0L, "")
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale form overwrote newer issue content")
    }
    assert_eq(require_issue(pool, scope, number).title, "Updated")
    mutate_issue(pool, scope, alice, latest, 2L, "close", "", "", 0L, "")
    let closed = require_issue(pool, scope, number)
    assert_eq(closed.status, "closed")
    mutate_issue(
      pool,
      scope,
      alice,
      closed,
      closed.edit_version,
      "reopen",
      "",
      "",
      0L,
      "",
    )
    assert_eq(require_issue(pool, scope, number).status, "open")
    try create_issue(pool, scope, alice, "Wrong assignee", "", bob.id) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("assigned an outsider")
    }
    assert_eq(create_issue(pool, scope, alice, "Second", "", 0L), 2L)
    assert_true(
      pool.with_client(client => {
        client.query_all("PRAGMA foreign_key_check").is_empty()
      }),
    )
  })
}

///|
async test "issues link only to merge requests in the same repository" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let other = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "public",
    })
    let issue = create_issue(pool, scope, alice, "Track work", "", 0L)
    ignore(create_issue(pool, other, alice, "Other repo", "", 0L))
    let git_dir = "\{root}/alice/demo.git"
    ignore(
      @test_support.merge_test_commit(
        git_dir,
        "fix",
        @gitops.branch_sha(git_dir, "master"),
        "Fix\n",
      ),
    )
    let mr = create_merge_request(
      pool,
      scope,
      git_dir,
      alice,
      "Fix tracked work",
      "",
      "fix",
      "master",
      false,
      issue~,
    )
    assert_eq(mr.issue_number, issue)
    let relation : Int64 = pool.with_client(client => {
      client
      .query_one("SELECT issue_id FROM merge_request WHERE id = ?", params=[
        mr.id,
      ])
      .get_name("issue_id")
    })
    assert_eq(relation, require_issue(pool, scope, issue).id)
    enqueue_merge(pool, scope, alice, mr, mr.version)
    assert_true(run_next_merge_job(pool, root))
    assert_eq(require_issue(pool, scope, issue).status, "open")
  })
}

///|
async test "read-only repository viewers cannot create issues or submit reviews" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let scope = @repository.repository_scope(pool, bob, {
      owner: "alice",
      name: "public",
    })
    let number = create_issue(pool, scope, alice, "Public issue", "", 0L)
    assert_eq(require_issue(pool, scope, number).title, "Public issue")
    try create_issue(pool, scope, bob, "Not allowed", "", 0L) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("read-only viewer created an issue")
    }
    let issue = require_issue(pool, scope, number)
    try
      mutate_issue(
        pool, scope, bob, issue, 1L, "comment", "", "", 0L, "Not allowed",
      )
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("read-only viewer commented")
    }
  })
}
