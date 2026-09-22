///|
async test "merge requests require version-bound approval and publish a two-parent merge" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let scope = @repository.repository_scope(pool, alice, repo)
    @repository.set_pipeline_push_enabled(pool, root, alice, repo, true)
    let original = @gitops.branch_sha(git_dir, "master")
    let source = @test_support.merge_test_commit(
      git_dir, "feature/one", original, "feature\n",
    )
    let mr = create_merge_request(
      pool, scope, git_dir, alice, "First MR", "Description", "feature/one", "master",
      false,
    )
    assert_eq(mr.number, 1L)
    assert_eq(mr.version, 1L)
    assert_eq(merge_revision(pool, mr).source_sha, source)
    save_branch_rule(pool, scope, git_dir, alice, "master", true, 1L)
    try enqueue_merge(pool, scope, alice, mr, mr.version) catch {
      @domain.BadRequest(_) | @gitops.Failure(_) => ()
      err => raise err
    } noraise {
      _ => fail("merged without required approval")
    }
    try submit_merge_review(pool, alice, mr, mr.version, "approved", "") catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("author approved their own MR")
    }
    submit_merge_review(pool, admin, mr, mr.version, "approved", "Reviewed")
    enqueue_merge(pool, scope, alice, mr, mr.version)
    try
      enqueue_merge(
        pool,
        scope,
        alice,
        require_merge_request(pool, scope, 1L),
        mr.version,
      )
    catch {
      @domain.BadRequest(_) | @gitops.Failure(_) => ()
      err => raise err
    } noraise {
      _ => fail("queued the same merge twice")
    }
    assert_true(run_next_merge_job(pool, root))
    let merged = require_merge_request(pool, scope, 1L)
    assert_eq(merged.status, "merged", msg=merged.job_error)
    assert_eq(merged.job_status, "succeeded")
    let events = @repository.list_ref_events(pool, alice, repo)
    assert_eq(events.length(), 1)
    assert_eq(events[0].state, "ready")
    assert_eq(events[0].reference, "refs/heads/master")
    assert_eq(events[0].commit_sha, merged.merged_sha)
    assert_eq(@gitops.branch_sha(git_dir, "master"), merged.merged_sha)
    assert_eq(
      @gitops.merge_git(git_dir, [
        "show",
        "-s",
        "--format=%P",
        merged.merged_sha,
      ])
      .trim()
      .to_owned(),
      "\{original} \{source}",
    )
    assert_eq(@gitops.branch_sha(git_dir, "feature/one"), source)
    assert_true(!run_next_merge_job(pool, root))
    assert_true(
      pool.with_client(client => {
        client.query_all("PRAGMA foreign_key_check").is_empty()
      }),
    )
  })
}

///|
async test "push invalidates approvals and stale queued merges never overwrite branches" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let scope = @repository.repository_scope(pool, alice, repo)
    let base = @gitops.branch_sha(git_dir, "master")
    let first = @test_support.merge_test_commit(
      git_dir, "feature", base, "one\n",
    )
    let mr = create_merge_request(
      pool, scope, git_dir, alice, "Changing source", "", "feature", "master", false,
    )
    save_branch_rule(pool, scope, git_dir, alice, "master", true, 1L)
    submit_merge_review(pool, admin, mr, 1L, "approved", "")
    enqueue_merge(pool, scope, alice, mr, 1L)
    let second = @test_support.merge_test_commit(
      git_dir, "feature", first, "two\n",
    )
    assert_true(run_next_merge_job(pool, root))
    let failed = require_merge_request(pool, scope, mr.number)
    assert_eq(failed.job_status, "failed")
    assert_true(
      failed.job_error.contains("branches changed"),
      msg=failed.job_error,
    )
    assert_eq(@gitops.branch_sha(git_dir, "master"), base)
    let latest = refresh_merge_request(pool, scope, git_dir, failed)
    assert_eq(latest.version, 2L)
    assert_eq(merge_revision(pool, latest).source_sha, second)
    assert_eq(merge_review_counts(pool, scope, latest).0, 0L)
    assert_eq(merge_revision(pool, latest, version=1L).source_sha, first)
    try submit_merge_review(pool, admin, latest, 1L, "approved", "") catch {
      @domain.BadRequest(_) | @gitops.Failure(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted review of a stale version")
    }
    submit_merge_review(pool, admin, latest, 2L, "approved", "")
    enqueue_merge(pool, scope, alice, latest, 2L)
    assert_true(run_next_merge_job(pool, root))
    assert_eq(require_merge_request(pool, scope, mr.number).status, "merged")
  })
}

///|
async test "drafts conflicts and changes requested block merges" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let scope = @repository.repository_scope(pool, alice, repo)
    let base = @gitops.branch_sha(git_dir, "master")
    ignore(
      @test_support.merge_test_commit(git_dir, "feature", base, "source\n"),
    )
    let mr = create_merge_request(
      pool, scope, git_dir, alice, "Draft", "", "feature", "master", true,
    )
    assert_true(
      merge_blocker(pool, scope, mr, merge_revision(pool, mr)).contains("Draft"),
    )
    edit_merge_request(pool, scope, alice, mr, "ready", "", "")
    let mr = require_merge_request(pool, scope, mr.number)
    submit_merge_review(
      pool,
      admin,
      mr,
      mr.version,
      "changes_requested",
      "Please change this",
    )
    assert_true(
      merge_blocker(pool, scope, mr, merge_revision(pool, mr)).contains(
        "Changes",
      ),
    )
    submit_merge_review(pool, admin, mr, mr.version, "withdrawn", "")
    assert_eq(merge_blocker(pool, scope, mr, merge_revision(pool, mr)), "")
    ignore(
      @test_support.merge_test_commit(
        git_dir, "master", base, "conflicting target\n",
      ),
    )
    let mr = refresh_merge_request(pool, scope, git_dir, mr)
    assert_eq(mr.version, 2L)
    assert_true(merge_revision(pool, mr).block_reason.contains("conflicts"))
    try enqueue_merge(pool, scope, alice, mr, mr.version) catch {
      @domain.BadRequest(_) | @gitops.Failure(_) => ()
      err => raise err
    } noraise {
      _ => fail("queued a conflicting merge")
    }
  })
}

///|
async test "merge execution rechecks permissions and deleted source branches" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let alice = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, alice, repo)
    let base = @gitops.branch_sha(git_dir, "master")
    ignore(
      @test_support.merge_test_commit(git_dir, "feature", base, "source\n"),
    )
    let mr = create_merge_request(
      pool, scope, git_dir, alice, "Permissions", "", "feature", "master", false,
    )
    enqueue_merge(pool, scope, alice, mr, mr.version)
    pool.with_client(client => {
      let _ = client.execute(
        "DELETE FROM team_member WHERE team_id = 1 AND user_id = 1",
      )
    })
    assert_true(run_next_merge_job(pool, root))
    assert_eq(
      require_merge_request(pool, scope, mr.number).job_status,
      "failed",
    )
    assert_eq(@gitops.branch_sha(git_dir, "master"), base)
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 1, 'owner')",
      )
    })
    enqueue_merge(
      pool,
      scope,
      alice,
      require_merge_request(pool, scope, mr.number),
      mr.version,
    )
    ignore(
      @gitops.merge_git(git_dir, ["update-ref", "-d", "refs/heads/feature"]),
    )
    assert_true(run_next_merge_job(pool, root))
    let failed = require_merge_request(pool, scope, mr.number)
    assert_eq(failed.job_status, "failed")
    assert_true(failed.job_error.contains("missing"), msg=failed.job_error)
    assert_eq(@gitops.branch_sha(git_dir, "master"), base)
    let revision = merge_revision(pool, mr)
    ignore(@gitops.merge_git(git_dir, ["cat-file", "-e", revision.source_sha]))
  })
}

///|
async test "merge recovery uses its atomic receipt even after a later target push" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let alice = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, alice, repo)
    @repository.set_pipeline_push_enabled(pool, root, alice, repo, true)
    let base = @gitops.branch_sha(git_dir, "master")
    let source = @test_support.merge_test_commit(
      git_dir, "feature", base, "source\n",
    )
    let mr = create_merge_request(
      pool, scope, git_dir, alice, "Recover", "", "feature", "master", false,
    )
    enqueue_merge(pool, scope, alice, mr, mr.version)
    let revision = merge_revision(pool, mr)
    let result = @gitops.merge_git(git_dir, [
        "commit-tree",
        revision.merge_tree,
        "-p",
        base,
        "-p",
        source,
        "-m",
        "Recovered merge",
      ])
      .trim()
      .to_owned()
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE merge_job SET status = 'running', result_sha = ? WHERE merge_request_id = ?",
        params=[result, mr.id],
      )
    })
    ignore(
      @gitops.merge_git(
        git_dir,
        ["update-ref", "--stdin"],
        input="start\nupdate refs/heads/master \{result} \{base}\ncreate refs/moonhub/merges/\{mr.id} \{result}\nprepare\ncommit\n",
      ),
    )
    let advanced = @test_support.merge_test_commit(
      git_dir, "master", result, "later push\n",
    )
    assert_true(run_next_merge_job(pool, root))
    let merged = require_merge_request(pool, scope, mr.number)
    assert_eq(merged.status, "merged")
    assert_eq(merged.merged_sha, result)
    let events = @repository.list_ref_events(pool, alice, repo)
    assert_eq(events.length(), 1)
    assert_eq(events[0].commit_sha, result)
    assert_eq(@gitops.branch_sha(git_dir, "master"), advanced)
    assert_true(!run_next_merge_job(pool, root))
    let count : Int64 = pool.with_client(client => {
      client
      .query_one(
        "SELECT COUNT(*) AS count FROM merge_activity WHERE merge_request_id = ? AND kind = 'merged'",
        params=[mr.id],
      )
      .get_name("count")
    })
    assert_eq(count, 1L)
  })
}

///|
async test "branch protection rejects direct updates deletes and internal refs" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let scope = @repository.repository_scope(pool, alice, repo)
    let sha = @gitops.branch_sha(git_dir, "master")
    let zero = "0".repeat(sha.length())
    authorize_received_refs(
      pool,
      alice,
      repo,
      "\{sha} \{sha} refs/heads/master\n",
    )
    save_branch_rule(pool, scope, git_dir, alice, "master", true, 1L)
    for
      update in [
        "\{sha} \{sha} refs/heads/master\n",
        "\{sha} \{zero} refs/heads/master\n",
        "\{zero} \{sha} refs/moonhub/merges/1\n",
      ] {
      try authorize_received_refs(pool, alice, repo, update) catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted protected or internal ref update")
      }
    }
    try
      authorize_received_refs(
        pool,
        bob,
        repo,
        "\{sha} \{sha} refs/heads/feature\n",
      )
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("nonmember pushed to private repository")
    }
    authorize_received_refs(
      pool,
      alice,
      repo,
      "\{zero} \{sha} refs/heads/feature\n\{zero} \{sha} refs/tags/v1\n",
    )
    save_branch_rule(pool, scope, git_dir, alice, "master", false, 0L)
    authorize_received_refs(
      pool,
      alice,
      repo,
      "\{sha} \{sha} refs/heads/master\n",
    )
  })
}

///|
async test "merge branch parser rejects ref expressions and unrelated histories" {
  @test_support.with_git_test_repo((_, git_dir) => {
    for
      branch in [
        "master~1", "master^{commit}", "-bad", "../master", "a..b", "a.lock", "",
        "master\n",
      ] {
      try @gitops.branch_sha(git_dir, branch) catch {
        @domain.BadRequest(_) | @gitops.Failure(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid branch: \{branch}")
      }
    }
    ignore(
      @gitops.merge_git(git_dir, [
        "symbolic-ref", "refs/heads/alias", "refs/heads/master",
      ]),
    )
    try @gitops.branch_sha(git_dir, "alias") catch {
      @domain.BadRequest(_) | @gitops.Failure(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted symbolic branch")
    }
    let tree = @gitops.merge_git(git_dir, ["rev-parse", "master^{tree}"])
      .trim()
      .to_owned()
    let orphan = @gitops.merge_git(git_dir, [
        "commit-tree", tree, "-m", "unrelated",
      ])
      .trim()
      .to_owned()
    ignore(
      @gitops.merge_git(git_dir, ["update-ref", "refs/heads/orphan", orphan]),
    )
    try @gitops.compare_branches(git_dir, "orphan", "master") catch {
      @domain.BadRequest(_) | @gitops.Failure(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted unrelated histories")
    }
  })
}

///|
async test "two queued merge requests cannot overwrite the same target" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let alice = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, alice, repo)
    let base = @gitops.branch_sha(git_dir, "master")
    ignore(@test_support.merge_test_commit(git_dir, "one", base, "one\n"))
    ignore(@test_support.merge_test_commit(git_dir, "two", base, "two\n"))
    let first = create_merge_request(
      pool, scope, git_dir, alice, "First", "", "one", "master", false,
    )
    let second = create_merge_request(
      pool, scope, git_dir, alice, "Second", "", "two", "master", false,
    )
    enqueue_merge(pool, scope, alice, first, first.version)
    enqueue_merge(pool, scope, alice, second, second.version)
    @async.with_task_group(group => {
      let one = group.spawn(() => run_next_merge_job(pool, root))
      let two = group.spawn(() => run_next_merge_job(pool, root))
      ignore(one.wait())
      ignore(two.wait())
    })
    ignore(run_next_merge_job(pool, root))
    let first = require_merge_request(pool, scope, first.number)
    let second = require_merge_request(pool, scope, second.number)
    assert_eq(first.status, "merged", msg=first.job_error)
    assert_eq(second.status, "open")
    assert_eq(second.job_status, "failed")
    assert_true(
      second.job_error.contains("branches changed"),
      msg=second.job_error,
    )
    assert_eq(@gitops.branch_sha(git_dir, "master"), first.merged_sha)
  })
}

///|
async test "draft and reopen cannot erase requests for changes" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let scope = @repository.repository_scope(pool, alice, repo)
    ignore(
      @test_support.merge_test_commit(
        git_dir,
        "reviewed",
        @gitops.branch_sha(git_dir, "master"),
        "review\n",
      ),
    )
    let mr = create_merge_request(
      pool, scope, git_dir, alice, "Review gate", "", "reviewed", "master", false,
    )
    submit_merge_review(
      pool, admin, mr, 1L, "changes_requested", "Needs changes",
    )
    edit_merge_request(pool, scope, alice, mr, "draft", "", "")
    edit_merge_request(
      pool,
      scope,
      alice,
      require_merge_request(pool, scope, mr.number),
      "ready",
      "",
      "",
    )
    edit_merge_request(
      pool,
      scope,
      alice,
      require_merge_request(pool, scope, mr.number),
      "close",
      "",
      "",
    )
    edit_merge_request(
      pool,
      scope,
      alice,
      require_merge_request(pool, scope, mr.number),
      "reopen",
      "",
      "",
    )
    let latest = require_merge_request(pool, scope, mr.number)
    assert_true(
      merge_blocker(pool, scope, latest, merge_revision(pool, latest)).contains(
        "Changes",
      ),
    )
  })
}

///|
async test "mismatched merge receipts fail closed without blocking other queued work" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let alice = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, alice, repo)
    let base = @gitops.branch_sha(git_dir, "master")
    let source = @test_support.merge_test_commit(
      git_dir, "mismatch", base, "source\n",
    )
    let mr = create_merge_request(
      pool, scope, git_dir, alice, "Receipt", "", "mismatch", "master", false,
    )
    enqueue_merge(pool, scope, alice, mr, 1L)
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE merge_job SET status = 'running', result_sha = ? WHERE merge_request_id = ?",
        params=[base, mr.id],
      )
    })
    ignore(
      @gitops.merge_git(git_dir, [
        "update-ref",
        "refs/moonhub/merges/\{mr.id}",
        source,
      ]),
    )
    assert_true(run_next_merge_job(pool, root))
    let failed = require_merge_request(pool, scope, mr.number)
    assert_eq(failed.job_status, "failed")
    assert_true(failed.job_error.contains("operator inspection"))
    assert_eq(@gitops.branch_sha(git_dir, "master"), base)
    assert_true(!run_next_merge_job(pool, root))
  })
}
