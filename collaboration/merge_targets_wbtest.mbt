///|
async test "retargeting identical commits versions reviews and merges only the new target" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let dir = repo.git_dir(root)
    let actor = @identity.active_user_by_name(pool, "alice")
    let reviewer = @identity.active_user_by_name(pool, "admin")
    let scope = @repository.repository_scope(pool, actor, repo)
    let base = @gitops.branch_sha(dir, "master")
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/release", base]))
    let source = @test_support.merge_test_commit(
      dir, "feature", base, "feature\n",
    )
    let mr = create_merge_request(
      pool, scope, dir, actor, "Original", "Body", "feature", "master", false,
    )
    save_branch_rule(pool, scope, dir, actor, "release", true, 1L)
    request_merge_review(pool, actor, scope, mr, reviewer.id, 1L)
    submit_merge_review(
      pool, reviewer, mr, 1L, "approved", "Approved old target",
    )
    let discussion = create_anchored_merge_discussion(
      pool,
      scope,
      reviewer,
      mr,
      dir,
      1L,
      None,
      "README.md",
      "new",
      1L,
      1L,
      "Keep the original anchor",
    )
    update_merge_request(
      pool, scope, dir, actor, mr, "Retargeted", "New body", "release", 1L,
    )
    let current = require_merge_request(pool, scope, mr.number)
    assert_eq(current.target, "release")
    assert_eq(current.title, "Retargeted")
    assert_eq(current.description, "New body")
    assert_eq(current.version, 2L)
    assert_eq(current.edit_version, 2L)
    assert_eq(merge_revision(pool, current).target_branch, "release")
    assert_eq(merge_revision(pool, current, version=1L).target_branch, "master")
    assert_eq(merge_revision(pool, current).target_sha, base)
    assert_eq(merge_review_counts(pool, scope, current).0, 0L)
    assert_eq(merge_review_counts(pool, scope, mr).0, 1L)
    let requests = review_requests(pool, actor, scope, current)
    assert_eq(requests[0].version, 2L)
    assert_true(requests[0].pending)
    let saved = merge_discussion(pool, scope, actor, current, discussion)
    assert_eq(saved.version, 1L)
    assert_true(saved.anchor is Some({ head_sha, .. }) && head_sha == source)
    pool.with_client(client => {
      let event = client.query_one(
        "SELECT * FROM merge_activity WHERE merge_request_id = ? AND kind = 'retargeted'",
        params=[mr.id],
      )
      assert_eq((event.get_name("actor_id") : Int64), actor.id)
      assert_eq((event.get_name("version") : Int64), 2L)
      assert_eq(
        (event.get_name("body") : String),
        "Changed target branch from `master` to `release`.",
      )
      assert_true(
        client.query_opt(
          "SELECT id FROM collaboration_event WHERE kind = 'retargeted' AND version = 2",
        )
        is Some(_),
      )
    })
    update_merge_request(
      pool,
      scope,
      dir,
      actor,
      current,
      current.title,
      current.description,
      "release",
      2L,
    )
    assert_eq(require_merge_request(pool, scope, mr.number).edit_version, 2L)
    try
      update_merge_request(
        pool, scope, dir, actor, mr, "Stale", "", "master", 1L,
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale edit accepted")
    }
    try enqueue_merge(pool, scope, actor, current, 1L) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("old revision accepted")
    }
    try enqueue_merge(pool, scope, actor, current, 2L) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("old approval counted for new target")
    }
    submit_merge_review(
      pool, reviewer, current, 2L, "approved", "Approved new target",
    )
    enqueue_merge(pool, scope, actor, current, 2L)
    try
      update_merge_request(
        pool, scope, dir, actor, current, "Busy", "", "master", 2L,
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("queued merge was retargeted")
    }
    assert_true(run_next_merge_job(pool, root))
    let merged = require_merge_request(pool, scope, mr.number)
    assert_eq(merged.status, "merged")
    assert_eq(@gitops.branch_sha(dir, "master"), base)
    assert_eq(@gitops.branch_sha(dir, "release"), merged.merged_sha)
    try
      update_merge_request(
        pool, scope, dir, actor, merged, "Merged", "", "master", 2L,
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("merged MR was retargeted")
    }
  })
}

///|
async test "retarget failures preserve metadata and draft and conflict comparisons remain editable" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let actor = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let scope = @repository.repository_scope(pool, actor, repo)
    let dir = repo.git_dir(root)
    let base = @gitops.branch_sha(dir, "master")
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/release", base]))
    let source = @test_support.merge_test_commit(
      dir, "feature", base, "source\n",
    )
    ignore(
      @gitops.merge_git(dir, ["update-ref", "refs/heads/included", source]),
    )
    let mr = create_merge_request(
      pool, scope, dir, actor, "Original", "Body", "feature", "master", true,
    )
    let duplicate = create_merge_request(
      pool, scope, dir, actor, "Duplicate", "", "feature", "release", false,
    )
    for target in ["feature", "missing", "--bad", "included", "release"] {
      try
        update_merge_request(
          pool, scope, dir, actor, mr, "Must roll back", "Changed", target, 1L,
        )
      catch {
        @domain.BadRequest(_) | @gitops.Failure(_) => ()
        err => raise err
      } noraise {
        _ => fail("invalid target accepted: " + target)
      }
      let current = require_merge_request(pool, scope, mr.number)
      assert_eq(current.target, "master")
      assert_eq(current.title, "Original")
      assert_eq(current.description, "Body")
      assert_eq(current.version, 1L)
      assert_eq(current.edit_version, 1L)
    }
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id,user_id,role) VALUES (?,?,'member')",
          params=[scope.team_id, bob.id],
        ),
      )
    })
    try
      update_merge_request(
        pool, scope, dir, bob, mr, "Denied", "", "release", 1L,
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("non-author member retargeted MR")
    }
    edit_merge_request(pool, scope, actor, duplicate, "close", "", "")
    update_merge_request(
      pool,
      scope,
      dir,
      actor,
      mr,
      mr.title,
      mr.description,
      "release",
      1L,
    )
    let draft = require_merge_request(pool, scope, mr.number)
    assert_true(draft.draft)
    assert_eq(draft.version, 2L)
    assert_true(merge_checks(pool, draft).is_empty())
    ignore(
      @test_support.merge_test_commit(
        dir, "conflict", base, "conflicting target\n",
      ),
    )
    update_merge_request(
      pool,
      scope,
      dir,
      actor,
      draft,
      draft.title,
      draft.description,
      "conflict",
      2L,
    )
    let conflicted = require_merge_request(pool, scope, mr.number)
    assert_eq(conflicted.target, "conflict")
    assert_false(merge_revision(pool, conflicted).block_reason.is_empty())
    assert_eq(merge_revision(pool, conflicted).merge_tree, "")
    edit_merge_request(pool, scope, actor, conflicted, "close", "", "")
    let closed = require_merge_request(pool, scope, mr.number)
    try
      update_merge_request(
        pool,
        scope,
        dir,
        actor,
        closed,
        "Closed",
        "",
        "master",
        closed.edit_version,
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("closed MR was retargeted")
    }
    assert_eq(require_merge_request(pool, scope, mr.number).target, "conflict")
    assert_true(
      pool.with_client(client => {
        client.query_all("PRAGMA foreign_key_check").is_empty()
      }),
    )
  })
}
