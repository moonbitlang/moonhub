///|
async fn with_merge_check_fixture(
  f : async (
    @database.Database,
    String,
    @repository.RepositoryScope,
    @domain.CurrentUser,
    @collaboration.MergeRequest,
  ) -> Unit,
  workflow~ : String = @test_support.single_job_workflow,
  required~ : Bool = true,
  authorize~ : Bool = true,
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, actor, protocol_repo)
    let dir = protocol_repo.git_dir(root)
    let base = @test_support.workflow_commit(dir, workflow)
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", base]))
    // The proposed change deletes its workflow; policy must still use target's.
    ignore(@test_support.merge_test_commit(dir, "feature", base, "MR source\n"))
    if required {
      @collaboration.save_branch_rule(
        pool,
        scope,
        dir,
        actor,
        "master",
        true,
        0L,
        checks=[".github/workflows/build.yml"],
      )
    }
    let mr = @collaboration.create_merge_request(
      pool,
      scope,
      dir,
      actor,
      "Check integration",
      "",
      "feature",
      "master",
      false,
      authorize_checks=authorize,
    )
    f(pool, root, scope, actor, mr)
  })
}

///|
let pull_request_workflow : String =
  #|name: MR CI
  #|on:
  #|  pull_request:
  #|    types: [opened, reopened, synchronize]
  #|jobs:
  #|  test:
  #|    runs-on: [self-hosted, linux]
  #|    steps:
  #|      - uses: actions/checkout@v4
  #|      - run: test -f README.md

///|
async test "pull request workflows discover without branch rules deduplicate and remain optional" {
  with_merge_check_fixture(
    (pool, root, scope, actor, mr) => {
      poll_merge_checks(pool, root)
      poll_merge_checks(pool, root)
      let runs = list_runs(pool, actor, protocol_repo)
      assert_eq(runs.length(), 1)
      assert_eq(runs[0].workflow_source, pull_request_workflow)
      assert_false(@collaboration.merge_checks(pool, mr)[0].required)
      let coordinator = merge_check_provider(pool)
      let (assignment, token) = claim_dag_attempt(coordinator, provider_secret)
      assert_eq(assignment.version, @protocol.action_assignment_version)
      assert_eq(assignment.job.steps[0].uses, "actions/checkout@v4")
      let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
      ignore(coordinator.start(id, token, 1))
      ignore(coordinator.complete(id, token, completion(conclusion="failure")))
      assert_eq(
        @collaboration.merge_blocker(
          pool,
          scope,
          mr,
          @collaboration.merge_revision(pool, mr),
        ),
        "",
      )
    },
    workflow=pull_request_workflow,
    required=false,
  )
}

///|
async test "pull request execution approval survives discovery but not a new source or reopen generation" {
  with_merge_check_fixture(
    (pool, root, scope, actor, mr) => {
      let dir = protocol_repo.git_dir(root)
      poll_merge_checks(pool, root)
      assert_eq(
        @collaboration.merge_checks(pool, mr)[0].state,
        "awaiting_approval",
      )
      assert_true(list_runs(pool, actor, protocol_repo).is_empty())
      @collaboration.approve_merge_checks(pool, scope, actor, mr, mr.version)
      poll_merge_checks(pool, root)
      let coordinator = merge_check_provider(pool)
      let (assignment, token) = claim_dag_attempt(coordinator, provider_secret)
      let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
      ignore(coordinator.start(id, token, 1))
      let source = @test_support.merge_test_commit(
        dir,
        "feature",
        @gitops.branch_sha(dir, "feature"),
        "new source\n",
      )
      poll_merge_checks(pool, root)
      let latest = @collaboration.require_merge_request(pool, scope, mr.number)
      assert_eq(latest.version, mr.version + 1L)
      assert_true(coordinator.heartbeat(id, token, 1).cancel_requested)
      assert_eq(
        @collaboration.merge_checks(pool, latest)[0].state,
        "awaiting_approval",
      )
      // Manager push authorization works without push workflows or branch rules.
      let next = @test_support.merge_test_commit(
        dir, "feature", source, "manager source\n",
      )
      @repository.record_received_transaction(
        pool,
        actor,
        scope.repo,
        "d".repeat(32),
        "prepared",
        "\{source} \{next} refs/heads/feature",
      )
      @repository.record_received_transaction(
        pool,
        actor,
        scope.repo,
        "d".repeat(32),
        "committed",
        "\{source} \{next} refs/heads/feature",
      )
      poll_merge_checks(pool, root)
      let pushed = @collaboration.require_merge_request(pool, scope, mr.number)
      assert_eq(@collaboration.merge_checks(pool, pushed)[0].state, "queued")
      @collaboration.edit_merge_request(
        pool, scope, actor, pushed, "close", "", "",
      )
      poll_merge_checks(pool, root)
      let closed = @collaboration.require_merge_request(pool, scope, mr.number)
      @collaboration.edit_merge_request(
        pool, scope, actor, closed, "reopen", "", "",
      )
      poll_merge_checks(pool, root)
      let reopened = @collaboration.require_merge_request(
        pool,
        scope,
        mr.number,
      )
      assert_true(
        @collaboration.merge_checks(pool, reopened)[0].run_number is Some(_),
      )
    },
    workflow=pull_request_workflow,
    required=false,
    authorize=false,
  )
}

///|
async test "pull request types filter opening and fire on source update and reopening" {
  let source = pull_request_workflow.replace_all(
    old="[opened, reopened, synchronize]",
    new="[reopened, synchronize]",
  )
  with_merge_check_fixture(
    (pool, root, scope, actor, mr) => {
      let dir = protocol_repo.git_dir(root)
      poll_merge_checks(pool, root)
      assert_true(@collaboration.merge_checks(pool, mr).is_empty())
      ignore(
        @test_support.merge_test_commit(
          dir,
          "feature",
          @gitops.branch_sha(dir, "feature"),
          "synchronize\n",
        ),
      )
      poll_merge_checks(pool, root)
      let updated = @collaboration.require_merge_request(pool, scope, mr.number)
      assert_eq(
        @collaboration.merge_checks(pool, updated)[0].state,
        "awaiting_approval",
      )
      @collaboration.edit_merge_request(
        pool, scope, actor, updated, "close", "", "",
      )
      let closed = @collaboration.require_merge_request(pool, scope, mr.number)
      @collaboration.edit_merge_request(
        pool, scope, actor, closed, "reopen", "", "",
      )
      let reopened = @collaboration.require_merge_request(
        pool,
        scope,
        mr.number,
      )
      @collaboration.prepare_merge_checks(pool, scope, reopened, actor~)
      poll_merge_checks(pool, root)
      assert_eq(@collaboration.merge_checks(pool, reopened)[0].state, "queued")
    },
    workflow=source,
    required=false,
  )
}

///|
async fn poll_merge_checks(pool : @database.Database, root : String) -> Unit {
  pool.with_client(client => {
    ignore(client.execute("UPDATE merge_request SET checks_poll_after = 0"))
  })
  assert_true(run_next_merge_check(pool, root))
}

///|
fn merge_check_provider(pool : @database.Database) -> Coordinator raise {
  let coordinator = Coordinator::new(pool)
  ignore(
    coordinator.create_provider(
      @identity.active_user_by_name(pool, "admin"),
      "mr-provider",
      provider_secret,
      ["self-hosted", "linux"],
      [protocol_repo],
    ),
  )
  coordinator
}

///|
fn finish_merge_check(
  coordinator : Coordinator,
  result~ : String = "success",
) -> Unit raise {
  let (assignment, token) = claim_dag_attempt(coordinator, provider_secret)
  let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
  ignore(coordinator.start(id, token, 1))
  ignore(coordinator.complete(id, token, completion(conclusion=result)))
}

///|
async test "MR checks pin merged trees use target workflow deduplicate and gate actual merges" {
  with_merge_check_fixture((pool, root, scope, actor, mr) => {
    let dir = protocol_repo.git_dir(root)
    let revision = @collaboration.merge_revision(pool, mr)
    assert_true(
      @collaboration.merge_blocker(pool, scope, mr, revision).has_prefix(
        "Required check",
      ),
    )
    try @collaboration.enqueue_merge(pool, scope, actor, mr, mr.version) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("unchecked merge queued")
    }
    poll_merge_checks(pool, root)
    poll_merge_checks(pool, root)
    let runs = list_runs(pool, actor, protocol_repo)
    assert_eq(
      runs.length(),
      1,
      msg=@collaboration.merge_checks(pool, mr)
        .map(check => check.state + ": " + check.error)
        .join("; "),
    )
    let run = runs[0]
    assert_eq(run.workflow_source, @test_support.single_job_workflow)
    assert_eq(
      @gitops.merge_git(dir, ["rev-parse", run.commit_sha + "^{tree}"])
      .trim()
      .to_owned(),
      revision.merge_tree,
    )
    assert_eq(
      @gitops.merge_git(dir, ["show", "-s", "--format=%P", run.commit_sha])
      .trim()
      .to_owned(),
      revision.target_sha + " " + revision.source_sha,
    )
    assert_eq(
      @gitops.merge_git(dir, ["rev-parse", run.source_ref]).trim().to_owned(),
      run.commit_sha,
    )
    let coordinator = merge_check_provider(pool)
    finish_merge_check(coordinator)
    assert_eq(@collaboration.merge_checks(pool, mr)[0].conclusion, "success")
    assert_eq(@collaboration.merge_blocker(pool, scope, mr, revision), "")
    @collaboration.enqueue_merge(pool, scope, actor, mr, mr.version)
    assert_true(@collaboration.run_next_merge_job(pool, root))
    let merged = @collaboration.require_merge_request(pool, scope, mr.number)
    assert_eq(merged.status, "merged", msg=merged.job_error)
    assert_eq(
      @gitops.merge_git(dir, ["rev-parse", merged.merged_sha + "^{tree}"])
      .trim()
      .to_owned(),
      revision.merge_tree,
    )
  })
}

///|
async test "MR reruns replace the gate result and older runs cannot be reused" {
  with_merge_check_fixture((pool, root, scope, actor, mr) => {
    poll_merge_checks(pool, root)
    let coordinator = merge_check_provider(pool)
    finish_merge_check(coordinator)
    let previous = list_runs(pool, actor, protocol_repo)[0]
    let next = rerun_run(pool, root, actor, protocol_repo, previous.number)
    assert_eq(next.commit_sha, previous.commit_sha)
    assert_eq(next.workflow_source, previous.workflow_source)
    let revision = @collaboration.merge_revision(pool, mr)
    assert_false(
      @collaboration.merge_blocker(pool, scope, mr, revision).is_empty(),
    )
    try rerun_run(pool, root, actor, protocol_repo, previous.number) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale rerun accepted")
    }
    finish_merge_check(coordinator, result="failure")
    assert_eq(@collaboration.merge_checks(pool, mr)[0].conclusion, "failure")
    assert_false(
      @collaboration.merge_blocker(pool, scope, mr, revision).is_empty(),
    )
    // A late repeat of an old terminal update cannot restore the old green.
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_run SET status = 'completed', conclusion = 'success' WHERE id = ?",
          params=[previous.id],
        ),
      )
    })
    assert_eq(@collaboration.merge_checks(pool, mr)[0].conclusion, "failure")
    ignore(rerun_run(pool, root, actor, protocol_repo, next.number))
    finish_merge_check(coordinator)
    assert_eq(@collaboration.merge_blocker(pool, scope, mr, revision), "")
  })
}

///|
async test "MR source changes cancel active checks and need explicit approval for untrusted pushes" {
  with_merge_check_fixture((pool, root, scope, actor, mr) => {
    let dir = protocol_repo.git_dir(root)
    poll_merge_checks(pool, root)
    let coordinator = merge_check_provider(pool)
    let (assignment, token) = claim_dag_attempt(coordinator, provider_secret)
    let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
    ignore(coordinator.start(id, token, 1))
    ignore(
      @test_support.merge_test_commit(
        dir,
        "feature",
        @gitops.branch_sha(dir, "feature"),
        "changed\n",
      ),
    )
    poll_merge_checks(pool, root)
    let latest = @collaboration.require_merge_request(pool, scope, mr.number)
    assert_eq(latest.version, mr.version + 1L)
    assert_eq(
      @collaboration.merge_checks(pool, latest)[0].state,
      "awaiting_approval",
    )
    assert_true(coordinator.heartbeat(id, token, 1).cancel_requested)
    ignore(coordinator.complete(id, token, completion()))
    assert_eq(
      get_run(pool, actor, protocol_repo, 1L).conclusion,
      Some(Cancelled),
    )
    assert_true(
      coordinator.claim(
        provider_secret,
        claim_request(id="3", secret="e".repeat(64)),
      )
      is None,
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
        ),
      )
    })
    let bob = @identity.active_user_by_name(pool, "bob")
    try
      @collaboration.approve_merge_checks(
        pool,
        scope,
        bob,
        latest,
        latest.version,
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("member approved execution")
    }
    try
      @collaboration.approve_merge_checks(
        pool,
        scope,
        actor,
        latest,
        mr.version,
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale approval accepted")
    }
    @collaboration.approve_merge_checks(
      pool,
      scope,
      actor,
      latest,
      latest.version,
    )
    poll_merge_checks(pool, root)
    finish_merge_check(coordinator)
    assert_eq(
      @collaboration.merge_blocker(
        pool,
        scope,
        latest,
        @collaboration.merge_revision(pool, latest),
      ),
      "",
    )
    assert_eq(list_runs(pool, actor, protocol_repo).length(), 2)
  })
}

///|
async test "MR draft close and policy changes fence queued checks immediately" {
  with_merge_check_fixture((pool, root, scope, actor, mr) => {
    let dir = protocol_repo.git_dir(root)
    poll_merge_checks(pool, root)
    let coordinator = merge_check_provider(pool)
    @collaboration.edit_merge_request(pool, scope, actor, mr, "draft", "", "")
    assert_true(coordinator.claim(provider_secret, claim_request()) is None)
    poll_merge_checks(pool, root)
    assert_eq(
      get_run(pool, actor, protocol_repo, 1L).conclusion,
      Some(Cancelled),
    )
    let draft = @collaboration.require_merge_request(pool, scope, mr.number)
    @collaboration.edit_merge_request(
      pool, scope, actor, draft, "ready", "", "",
    )
    let ready = @collaboration.require_merge_request(pool, scope, mr.number)
    @collaboration.approve_merge_checks(
      pool,
      scope,
      actor,
      ready,
      ready.version,
    )
    poll_merge_checks(pool, root)
    finish_merge_check(coordinator)
    @collaboration.edit_merge_request(
      pool, scope, actor, ready, "close", "", "",
    )
    let closed = @collaboration.require_merge_request(pool, scope, mr.number)
    @collaboration.edit_merge_request(
      pool, scope, actor, closed, "reopen", "", "",
    )
    let reopened = @collaboration.require_merge_request(pool, scope, mr.number)
    assert_false(
      @collaboration.merge_blocker(
        pool,
        scope,
        reopened,
        @collaboration.merge_revision(pool, reopened),
      ).is_empty(),
    )
    @collaboration.approve_merge_checks(
      pool,
      scope,
      actor,
      reopened,
      reopened.version,
    )
    poll_merge_checks(pool, root)
    @collaboration.save_branch_rule(
      pool,
      scope,
      dir,
      actor,
      "master",
      true,
      0L,
      checks=[".github/workflows/other.yml"],
    )
    assert_true(coordinator.claim(provider_secret, claim_request()) is None)
    poll_merge_checks(pool, root)
    assert_eq(
      get_run(pool, actor, protocol_repo, 3L).conclusion,
      Some(Cancelled),
    )
  })
}

///|
async test "MR worker and merge worker reject changed target and revoked permissions" {
  with_merge_check_fixture((pool, root, scope, actor, mr) => {
    let dir = protocol_repo.git_dir(root)
    poll_merge_checks(pool, root)
    let coordinator = merge_check_provider(pool)
    finish_merge_check(coordinator)
    @collaboration.enqueue_merge(pool, scope, actor, mr, mr.version)
    let old = @gitops.branch_sha(dir, "master")
    let tree = @gitops.merge_git(dir, ["rev-parse", old + "^{tree}"])
      .trim()
      .to_owned()
    let next = @gitops.merge_git(dir, [
        "commit-tree", tree, "-p", old, "-m", "Target advanced",
      ])
      .trim()
      .to_owned()
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", next]))
    assert_true(@collaboration.run_next_merge_job(pool, root))
    assert_eq(@gitops.branch_sha(dir, "master"), next)
    assert_eq(
      @collaboration.require_merge_request(pool, scope, mr.number).job_status,
      "failed",
    )
    poll_merge_checks(pool, root)
    let latest = @collaboration.require_merge_request(pool, scope, mr.number)
    assert_eq(latest.version, mr.version + 1L)
    assert_false(
      @collaboration.merge_blocker(
        pool,
        scope,
        latest,
        @collaboration.merge_revision(pool, latest),
      ).is_empty(),
    )
    assert_eq(list_runs(pool, actor, protocol_repo).length(), 2)
    coordinator.cancel_run(actor, protocol_repo, 2L)
    @collaboration.approve_merge_checks(
      pool,
      scope,
      actor,
      latest,
      latest.version,
    )
    // Exercise revoked authorization on a fresh approved generation.
    @collaboration.edit_merge_request(
      pool, scope, actor, latest, "draft", "", "",
    )
    let draft = @collaboration.require_merge_request(pool, scope, mr.number)
    @collaboration.edit_merge_request(
      pool, scope, actor, draft, "ready", "", "",
    )
    let latest = @collaboration.require_merge_request(pool, scope, mr.number)
    @collaboration.approve_merge_checks(
      pool,
      scope,
      actor,
      latest,
      latest.version,
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE team_member SET role = 'member' WHERE team_id = 1 AND user_id = 1",
        ),
      )
    })
    poll_merge_checks(pool, root)
    assert_eq(@collaboration.merge_checks(pool, latest)[0].state, "error")
    assert_eq(list_runs(pool, actor, protocol_repo).length(), 2)
  })
}

///|
async test "MR required workflows fail closed when target config is absent and manager pushes authorize new versions" {
  with_merge_check_fixture((pool, root, scope, actor, mr) => {
    let dir = protocol_repo.git_dir(root)
    let old = @gitops.branch_sha(dir, "feature")
    let next = @test_support.merge_test_commit(
      dir, "scratch", old, "push fixture\n",
    )
    @repository.record_received_transaction(
      pool,
      actor,
      protocol_repo,
      "c".repeat(32),
      "prepared",
      "\{old} \{next} refs/heads/feature",
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/feature", next]))
    @repository.record_received_transaction(
      pool,
      actor,
      protocol_repo,
      "c".repeat(32),
      "committed",
      "\{old} \{next} refs/heads/feature",
    )
    poll_merge_checks(pool, root)
    let latest = @collaboration.require_merge_request(pool, scope, mr.number)
    assert_eq(@collaboration.merge_checks(pool, latest)[0].state, "queued")
    assert_eq(list_runs(pool, actor, protocol_repo).length(), 1)
    @collaboration.save_branch_rule(
      pool,
      scope,
      dir,
      actor,
      "master",
      true,
      0L,
      checks=[".github/workflows/missing.yml"],
    )
    poll_merge_checks(pool, root)
    assert_eq(@collaboration.merge_checks(pool, latest)[0].state, "error")
    assert_false(
      @collaboration.merge_blocker(
        pool,
        scope,
        latest,
        @collaboration.merge_revision(pool, latest),
      ).is_empty(),
    )
    poll_merge_checks(pool, root)
    assert_eq(list_runs(pool, actor, protocol_repo).length(), 1)
  })
}

///|
async test "pull request required checks keep the merge gate and target advances rerun the same approved source" {
  with_merge_check_fixture(
    (pool, root, scope, actor, mr) => {
      let dir = protocol_repo.git_dir(root)
      poll_merge_checks(pool, root)
      assert_true(@collaboration.merge_checks(pool, mr)[0].required)
      assert_eq(list_runs(pool, actor, protocol_repo).length(), 1)
      let coordinator = merge_check_provider(pool)
      finish_merge_check(coordinator, result="failure")
      assert_true(
        @collaboration.merge_blocker(
          pool,
          scope,
          mr,
          @collaboration.merge_revision(pool, mr),
        ).has_prefix("Required check"),
      )
      let target = @gitops.branch_sha(dir, "master")
      let tree = @gitops.merge_git(dir, ["rev-parse", target + "^{tree}"])
        .trim()
        .to_owned()
      let next = @gitops.merge_git(dir, [
          "commit-tree", tree, "-p", target, "-m", "target advances",
        ])
        .trim()
        .to_owned()
      ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", next]))
      poll_merge_checks(pool, root)
      let latest = @collaboration.require_merge_request(pool, scope, mr.number)
      assert_eq(latest.version, mr.version + 1L)
      assert_eq(@collaboration.merge_checks(pool, latest)[0].state, "queued")
      assert_eq(list_runs(pool, actor, protocol_repo).length(), 2)
      finish_merge_check(coordinator)
      assert_eq(
        @collaboration.merge_blocker(
          pool,
          scope,
          latest,
          @collaboration.merge_revision(pool, latest),
        ),
        "",
      )
    },
    workflow=pull_request_workflow,
  )
}

///|
async test "optional pull request runs stop when their approving manager loses access" {
  with_merge_check_fixture(
    (pool, root, scope, actor, mr) => {
      poll_merge_checks(pool, root)
      let coordinator = merge_check_provider(pool)
      let (assignment, token) = claim_dag_attempt(coordinator, provider_secret)
      let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
      ignore(coordinator.start(id, token, 1))
      pool.with_client(client => {
        ignore(
          client.execute(
            "UPDATE team_member SET role = 'member' WHERE team_id = ? AND user_id = ?",
            params=[scope.team_id, actor.id],
          ),
        )
      })
      assert_true(coordinator.heartbeat(id, token, 1).cancel_requested)
      assert_false(@collaboration.merge_checks(pool, mr)[0].required)
    },
    workflow=pull_request_workflow,
    required=false,
  )
}

///|
async test "reopening discovers source changes made while closed as reopened then later pushes synchronize" {
  let workflow = pull_request_workflow.replace_all(
    old="[opened, reopened, synchronize]",
    new="[reopened]",
  )
  with_merge_check_fixture(
    (pool, root, scope, actor, mr) => {
      let dir = protocol_repo.git_dir(root)
      poll_merge_checks(pool, root)
      @collaboration.edit_merge_request(pool, scope, actor, mr, "close", "", "")
      ignore(
        @test_support.merge_test_commit(
          dir,
          "feature",
          @gitops.branch_sha(dir, "feature"),
          "while closed\n",
        ),
      )
      let closed = @collaboration.require_merge_request(pool, scope, mr.number)
      @collaboration.edit_merge_request(
        pool, scope, actor, closed, "reopen", "", "",
      )
      poll_merge_checks(pool, root)
      let reopened = @collaboration.require_merge_request(
        pool,
        scope,
        mr.number,
      )
      assert_eq(reopened.version, mr.version + 1L)
      assert_eq(@collaboration.merge_checks(pool, reopened).length(), 1)
      ignore(
        @test_support.merge_test_commit(
          dir,
          "feature",
          @gitops.branch_sha(dir, "feature"),
          "after reopen\n",
        ),
      )
      poll_merge_checks(pool, root)
      let latest = @collaboration.require_merge_request(pool, scope, mr.number)
      assert_true(@collaboration.merge_checks(pool, latest).is_empty())
    },
    workflow~,
    required=false,
  )
}

///|
async test "oversized workflow records a preparation error without starving required checks" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, actor, protocol_repo)
    let dir = protocol_repo.git_dir(root)
    let workflow_blob = @gitops.merge_git(
        dir,
        ["hash-object", "-w", "--stdin"],
        input=@test_support.single_job_workflow,
      )
      .trim()
      .to_owned()
    let large_blob = @gitops.merge_git(
        dir,
        ["hash-object", "-w", "--stdin"],
        input="name: Unrelated\non: workflow_dispatch\n#" + "x".repeat(66000),
      )
      .trim()
      .to_owned()
    let workflows = @gitops.merge_git(
        dir,
        ["mktree"],
        input="100644 blob \{workflow_blob}\tbuild.yml\n100644 blob \{large_blob}\tunrelated.yml\n",
      )
      .trim()
      .to_owned()
    let github = @gitops.merge_git(
        dir,
        ["mktree"],
        input="040000 tree \{workflows}\tworkflows\n",
      )
      .trim()
      .to_owned()
    let tree = @gitops.merge_git(
        dir,
        ["mktree"],
        input="040000 tree \{github}\t.github\n",
      )
      .trim()
      .to_owned()
    let base = @gitops.merge_git(dir, [
        "commit-tree", tree, "-m", "Target config",
      ])
      .trim()
      .to_owned()
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", base]))
    ignore(@test_support.merge_test_commit(dir, "feature", base, "feature\n"))
    @collaboration.save_branch_rule(
      pool,
      scope,
      dir,
      actor,
      "master",
      true,
      0L,
      checks=[".github/workflows/build.yml"],
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, dir, actor, "review repro", "", "feature", "master", false,
    )
    poll_merge_checks(pool, root)
    poll_merge_checks(pool, root)
    let runs = list_runs(pool, actor, protocol_repo)
    assert_eq(runs.length(), 1)
    assert_eq(runs[0].workflow_path, ".github/workflows/build.yml")
    let checks = @collaboration.merge_checks(pool, mr)
    assert_eq(checks.length(), 2)
    assert_eq(checks[0].state, "queued")
    assert_true(checks[0].required)
    assert_eq(checks[1].state, "error")
    assert_false(checks[1].required)
    assert_true(checks[1].error.contains("too large"))
    assert_true(checks[1].run_number is None)
    let coordinator = merge_check_provider(pool)
    finish_merge_check(coordinator)
    assert_eq(
      @collaboration.merge_blocker(
        pool,
        scope,
        mr,
        @collaboration.merge_revision(pool, mr),
      ),
      "",
    )
  })
}

///|
async test "reopening observes source before a subsequent push triggers synchronize" {
  with_merge_check_fixture(
    (pool, root, scope, actor, mr) => {
      let dir = protocol_repo.git_dir(root)
      poll_merge_checks(pool, root)
      @collaboration.edit_merge_request(pool, scope, actor, mr, "close", "", "")
      let closed = @collaboration.require_merge_request(pool, scope, mr.number)
      @collaboration.edit_merge_request(
        pool, scope, actor, closed, "reopen", "", "",
      )
      // Browser reopen observes refs before redirecting; worker discovery can lag.
      let reopened = @collaboration.refresh_merge_request(
        pool,
        scope,
        dir,
        @collaboration.require_merge_request(pool, scope, mr.number),
      )
      @collaboration.prepare_merge_checks(pool, scope, reopened, actor~)
      ignore(
        @test_support.merge_test_commit(
          dir,
          "feature",
          @gitops.branch_sha(dir, "feature"),
          "new push after reopen\n",
        ),
      )
      poll_merge_checks(pool, root)
      let latest = @collaboration.require_merge_request(pool, scope, mr.number)
      assert_eq(
        @collaboration.merge_checks(pool, latest).length(),
        1,
        msg="synchronize-only workflow disappeared after push",
      )
    },
    workflow=pull_request_workflow.replace_all(
      old="[opened, reopened, synchronize]",
      new="[synchronize]",
    ),
    required=false,
  )
}
