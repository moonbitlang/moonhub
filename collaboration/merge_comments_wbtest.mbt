///|
async test "comment deletion is scoped reversible and cannot change review decisions" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let bob = @identity.active_user_by_name(pool, "bob")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let dir = repo.git_dir(root)
    let base = @gitops.branch_sha(dir, "master")
    ignore(@test_support.merge_test_commit(dir, "comments", base, "comments\n"))
    let mr = create_merge_request(
      pool, scope, dir, alice, "Comments", "", "comments", "master", false,
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id, user_id, role) VALUES (?, ?, 'member')",
          params=[scope.team_id, bob.id],
        ),
      )
    })
    submit_merge_review(pool, alice, mr, 1L, "comment", "Redundant text")
    let comment = list_merge_activity(pool, mr, 1L)[0]
    assert_eq(comment.actor_id, Some(alice.id))
    try
      set_merge_comment_deleted(pool, scope, bob, mr, comment.id, 1L, true)
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("member deleted another author's comment")
    }
    try
      set_merge_comment_deleted(pool, scope, alice, mr, comment.id, 2L, true)
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("wrong comment revision accepted")
    }
    submit_merge_review(pool, admin, mr, 1L, "approved", "Reviewed")
    let approval = list_merge_activity(pool, mr, 1L)[0]
    try
      set_merge_comment_deleted(pool, scope, admin, mr, approval.id, 1L, true)
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("approval activity deleted")
    }
    set_merge_comment_deleted(pool, scope, alice, mr, comment.id, 1L, true)
    set_merge_comment_deleted(pool, scope, alice, mr, comment.id, 1L, true)
    let deleted = list_merge_activity(pool, mr, 1L)[1]
    assert_eq(deleted.id, comment.id)
    assert_eq(deleted.kind, "comment_deleted")
    assert_eq(deleted.body, "")
    pool.with_client(client => {
      let body : String = client
        .query_one("SELECT body FROM merge_activity WHERE id = ?", params=[
          comment.id,
        ])
        .get_name("body")
      assert_eq(body, "")
      let count : Int64 = client
        .query_one(
          "SELECT COUNT(*) AS count FROM repository_audit WHERE kind = 'mr_comment_deleted'",
        )
        .get_name("count")
      assert_eq(count, 1L)
    })
    assert_eq(merge_review_counts(pool, scope, mr).0, 1L)
    set_merge_comment_deleted(pool, scope, admin, mr, comment.id, 1L, false)
    let restored = list_merge_activity(pool, mr, 1L)[1]
    assert_eq(restored.body, "Redundant text")
    assert_eq(restored.kind, "comment")
    assert_eq(merge_review_counts(pool, scope, mr).0, 1L)
    // Use the comment revision even after the MR has advanced or closed.
    ignore(@test_support.merge_test_commit(dir, "comments", base, "updated\n"))
    let latest = refresh_merge_request(pool, scope, dir, mr)
    assert_eq(latest.version, 2L)
    set_merge_comment_deleted(pool, scope, alice, latest, comment.id, 1L, true)
    edit_merge_request(pool, scope, alice, latest, "close", "", "")
    let closed = require_merge_request(pool, scope, mr.number)
    set_merge_comment_deleted(pool, scope, alice, closed, comment.id, 1L, false)
    assert_eq(
      list_merge_activity(pool, closed, 1L)
      .iter()
      .find_first(item => item.id == comment.id)
      .unwrap().body,
      "Redundant text",
    )
    ignore(@test_support.merge_test_commit(dir, "other", base, "other\n"))
    let other = create_merge_request(
      pool, scope, dir, alice, "Other", "", "other", "master", false,
    )
    try
      set_merge_comment_deleted(pool, scope, alice, other, comment.id, 1L, true)
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("cross-MR deletion accepted")
    }
  })
}
