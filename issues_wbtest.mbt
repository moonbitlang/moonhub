///|
async test "issues preserve authors assignees and reject stale edits" {
  with_ssh_test_db(pool => {
    let alice = active_user_by_name(pool, "alice")
    let bob = active_user_by_name(pool, "bob")
    let admin = active_user_by_name(pool, "admin")
    let scope = repository_scope(pool, alice, { owner: "alice", name: "demo", })
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
      NotFound(_) => ()
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
      BadRequest(_) => ()
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
      BadRequest(_) => ()
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
async test "issue pages enforce repository permissions CSRF and output escaping" {
  with_repository_test_app((port, pool, _, alice, bob) => {
    let (denied, _) = http_get_path_with_cookie(port, "/alice/demo/issues", bob)
    assert_eq(denied.code, 404)
    let (_, form) = http_get_path_with_cookie(
      port, "/alice/demo/issues/new", alice,
    )
    let token = extract_attr(form, "name=\"csrf_token\"", "value=\"")
    let (forged, _) = http_post_path_with_cookie(
      port, "/alice/demo/issues", "title=Issue&assignee=1", alice,
    )
    assert_eq(forged.code, 403)
    let (created, _) = http_post_path_with_cookie(
      port,
      "/alice/demo/issues",
      "csrf_token=\{token}&title=Issue&description=%3Cscript%3Ebad%3C%2Fscript%3E&assignee=1",
      alice,
    )
    assert_eq(created.code, 303)
    assert_true(created.headers.get("location") is Some("/alice/demo/issues/1"))
    let (detail, body) = http_get_path_with_cookie(
      port, "/alice/demo/issues/1", alice,
    )
    assert_eq(detail.code, 200)
    assert_true(detail.headers.get("cache-control") is Some("no-store"))
    assert_true(body.contains("&lt;script&gt;bad&lt;/script&gt;"))
    assert_true(!body.contains("<script>bad</script>"))
    let (commented, _) = http_post_path_with_cookie(
      port,
      "/alice/demo/issues/1/comment",
      "csrf_token=\{token}&body=Details",
      alice,
    )
    assert_eq(commented.code, 303)
    let (closed, _) = http_post_path_with_cookie(
      port,
      "/alice/demo/issues/1/close",
      "csrf_token=\{token}&edit_version=1",
      alice,
    )
    assert_eq(closed.code, 303)
    let (_, list) = http_get_path_with_cookie(
      port, "/alice/demo/issues?status=closed&assigned=me&q=Issue", alice,
    )
    assert_true(list.contains("/alice/demo/issues/1"))
    let (stale, _) = http_post_path_with_cookie(
      port,
      "/alice/demo/issues/1/reopen",
      "csrf_token=\{token}&edit_version=1",
      alice,
    )
    assert_eq(stale.code, 400)
    let scope = repository_scope(pool, active_user_by_name(pool, "alice"), {
      owner: "alice",
      name: "demo",
    })
    assert_eq(require_issue(pool, scope, 1L).status, "closed")
  })
}

///|
async test "issues link only to merge requests in the same repository" {
  with_repository_test_app((_, pool, root, _, _) => {
    let alice = active_user_by_name(pool, "alice")
    let scope = repository_scope(pool, alice, { owner: "alice", name: "demo", })
    let other = repository_scope(pool, alice, {
      owner: "alice",
      name: "public",
    })
    let issue = create_issue(pool, scope, alice, "Track work", "", 0L)
    ignore(create_issue(pool, other, alice, "Other repo", "", 0L))
    let git_dir = "\{root}/alice/demo.git"
    ignore(
      merge_test_commit(
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
  with_ssh_test_db(pool => {
    let alice = active_user_by_name(pool, "alice")
    let bob = active_user_by_name(pool, "bob")
    let scope = repository_scope(pool, bob, { owner: "alice", name: "public", })
    let number = create_issue(pool, scope, alice, "Public issue", "", 0L)
    assert_eq(require_issue(pool, scope, number).title, "Public issue")
    try create_issue(pool, scope, bob, "Not allowed", "", 0L) catch {
      NotFound(_) => ()
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
      NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("read-only viewer commented")
    }
  })
}
