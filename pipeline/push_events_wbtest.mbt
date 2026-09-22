///|
async test "push intents recover after ref commit and run exact snapshots once despite later pushes" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let actor = @identity.active_user_by_name(pool, "alice")
    let git_dir = repo.git_dir(root)
    let scope = @repository.repository_scope(pool, actor, repo)
    let first = @test_support.workflow_commit(
      git_dir,
      @test_support.single_job_workflow.replace_all(
        old="on: workflow_dispatch",
        new="on: [push, workflow_dispatch]",
      ),
    )
    @repository.set_pipeline_push_enabled(pool, root, actor, repo, true)
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "a".repeat(32),
      "prepared",
      "\{"0".repeat(40)} \{first} refs/heads/one",
    )
    ignore(@gitops.merge_git(git_dir, ["update-ref", "refs/heads/one", first]))
    // The process dies before the committed callback; recovery must confirm the ref.
    @repository.recover_ref_events_locked(pool, scope, git_dir)
    let second = @test_support.workflow_commit(
      git_dir,
      @test_support.single_job_workflow
      .replace_all(old="on: workflow_dispatch", new="on: push")
      .replace_all(old="echo fixture", new="echo second"),
    )
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "b".repeat(32),
      "prepared",
      "\{first} \{second} refs/heads/one",
    )
    ignore(@gitops.merge_git(git_dir, ["update-ref", "refs/heads/one", second]))
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "b".repeat(32),
      "committed",
      "\{first} \{second} refs/heads/one",
    )
    @repository.recover_ref_events_locked(pool, scope, git_dir)
    assert_true(run_next_push_event(pool, root))
    assert_true(run_next_push_event(pool, root))
    let runs = list_runs(pool, actor, repo)
    assert_eq(runs.length(), 2)
    assert_eq(runs[0].commit_sha, second)
    assert_eq(runs[1].commit_sha, first)
    assert_eq(runs[0].definition.jobs[0].steps[0].run, "echo second")
    assert_eq(runs[1].definition.jobs[0].steps[0].run, "echo fixture")
    // Recover a worker crash after committing a run but before finishing its event.
    pool.with_client(client => {
      ignore(client.execute("UPDATE repository_ref_event SET state = 'ready'"))
    })
    assert_true(run_next_push_event(pool, root))
    assert_true(run_next_push_event(pool, root))
    assert_false(run_next_push_event(pool, root))
    assert_eq(list_runs(pool, actor, repo).length(), 2)
    for run in runs {
      assert_eq(
        @gitops.merge_git(git_dir, ["rev-parse", run.source_ref])
        .trim()
        .to_owned(),
        run.commit_sha,
      )
    }
  })
}

///|
async test "push trigger settings filters invalid workflows aborted updates and revoked authors fail closed" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let actor = @identity.active_user_by_name(pool, "alice")
    let git_dir = repo.git_dir(root)
    let scope = @repository.repository_scope(pool, actor, repo)
    let sha = @test_support.workflow_commit(
      git_dir,
      @test_support.single_job_workflow.replace_all(
        old="on: workflow_dispatch",
        new="on: {push: {branches: [main]}}",
      ),
    )
    let updates = "\{"0".repeat(40)} \{sha} refs/heads/feature"
    assert_false(@repository.pipeline_push_enabled(pool, actor, repo))
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "a".repeat(32),
      "prepared",
      updates,
    )
    assert_true(@repository.list_ref_events(pool, actor, repo).is_empty())
    @repository.set_pipeline_push_enabled(pool, root, actor, repo, true)
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "a".repeat(32),
      "prepared",
      updates,
    )
    @repository.recover_ref_events_locked(pool, scope, git_dir)
    assert_eq(
      @repository.list_ref_events(pool, actor, repo)[0].state,
      "aborted",
    )
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "b".repeat(32),
      "prepared",
      updates,
    )
    ignore(
      @gitops.merge_git(git_dir, ["update-ref", "refs/heads/feature", sha]),
    )
    assert_true(run_next_push_event(pool, root))
    assert_true(list_runs(pool, actor, repo).is_empty())
    let invalid = @test_support.workflow_commit(
      git_dir,
      @test_support.single_job_workflow
      .replace_all(old="on: workflow_dispatch", new="on: push")
      .replace_all(old="run: echo fixture", new="uses: something"),
    )
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "c".repeat(32),
      "prepared",
      "\{sha} \{invalid} refs/heads/feature",
    )
    ignore(
      @gitops.merge_git(git_dir, ["update-ref", "refs/heads/feature", invalid]),
    )
    assert_true(run_next_push_event(pool, root))
    assert_false(
      @repository.list_ref_events(pool, actor, repo)[0].error.is_empty(),
    )
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "d".repeat(32),
      "prepared",
      "\{"0".repeat(40)} \{sha} refs/heads/main",
    )
    ignore(@gitops.merge_git(git_dir, ["update-ref", "refs/heads/main", sha]))
    pool.with_client(client => {
      ignore(
        client.execute(
          "DELETE FROM team_member WHERE user_id = ? AND team_id = ?",
          params=[actor.id, scope.team_id],
        ),
      )
    })
    assert_true(run_next_push_event(pool, root))
    let admin = @identity.active_user_by_name(pool, "admin")
    assert_true(list_runs(pool, admin, repo).is_empty())
    assert_false(
      @repository.list_ref_events(pool, admin, repo)[0].error.is_empty(),
    )
  })
}
