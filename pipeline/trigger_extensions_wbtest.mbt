///|
async test "tag pushes peel annotated tags preserve event refs and isolate cache scope" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo = protocol_repo
    let dir = repo.git_dir(root)
    let source = @test_support.single_job_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: {push: {tags: ['v*', '!v*-beta*'], paths: ['never/**']}}",
    )
    let sha = @test_support.workflow_commit(dir, source)
    @repository.set_pipeline_push_enabled(pool, root, actor, repo, true)
    for (name, key) in [("v1", "a"), ("v1-beta1", "b")] {
      ignore(
        @gitops.merge_git(dir, ["tag", "-a", name, sha, "-m", "tag fixture"]),
      )
      let tag = @gitops.merge_git(dir, ["rev-parse", "refs/tags/" + name])
        .trim()
        .to_owned()
      let update = "0".repeat(40) + " " + tag + " refs/tags/" + name
      @repository.record_received_transaction(
        pool,
        actor,
        repo,
        key.repeat(32),
        "prepared",
        update,
      )
      @repository.record_received_transaction(
        pool,
        actor,
        repo,
        key.repeat(32),
        "committed",
        update,
      )
      assert_true(run_next_ref_event(pool, root))
    }
    let runs = @runtime.list_runs(pool, actor, repo)
    assert_eq(runs.length(), 1)
    assert_eq(runs[0].commit_sha, sha)
    assert_eq(runs[0].context.unwrap().event_name, "push")
    assert_eq(
      runs[0].context.unwrap().event.unwrap().get("ref"),
      Some(Json::string("refs/tags/v1")),
    )
    assert_eq(
      pool.with_client(c => {
        (
          c
          .query_one("SELECT scope FROM pipeline_cache_scope WHERE run_id=?", params=[
            runs[0].id,
          ])
          .get_name("scope") : String)
      }),
      "refs/tags/v1",
    )
    let c = merge_check_provider(pool)
    let (a, _) = claim_dag_attempt(c, provider_secret)
    assert_eq(a.job.context.get("ref"), Some("refs/tags/v1"))
  })
}

///|
async test "workflow completion events deduplicate persist upstream context and bound chains" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo = protocol_repo
    pool.with_client(c => {
      ignore(
        c.execute("UPDATE repository SET default_branch='master' WHERE id=1"),
      )
    })
    let dir = repo.git_dir(root)
    let source = @test_support.single_job_workflow.replace_all(
      old="name: Protocol fixture",
      new="name: Upstream",
    )
    let watch = @test_support.single_job_workflow
      .replace_all(old="name: Protocol fixture", new="name: Watch")
      .replace_all(
        old="on: workflow_dispatch",
        new="on: {workflow_run: {workflows: [Upstream, Watch], types: [completed], branches: [master]}}",
      )
    let parent = @gitops.branch_sha(dir, "master")
    let sha = merge_check_commit(dir, "master", parent, "events", workflows=[
      ("build.yml", source),
      ("watch.yml", watch),
    ])
    let run = create_run(
      pool, root, actor, repo, "master", ".github/workflows/build.yml",
    )
    let c = merge_check_provider(pool)
    c.runtime.cancel_run(actor, repo, run.number)
    c.runtime.cancel_run(actor, repo, run.number)
    assert_true(run_next_workflow_event(pool, root))
    let downstream = @runtime.list_runs(pool, actor, repo)[0]
    assert_eq(downstream.workflow_name, "Watch")
    assert_true(
      downstream.context.unwrap().event.unwrap().get("workflow_run")
      is Some(
        {
          "id": Number(id, ..),
          "run_attempt": 1,
          "conclusion": "cancelled",
          "head_branch": "master",
          "head_sha": String(head),
          ..
        },
      ) &&
      id == run.public_id.to_double() &&
      head == sha,
    )
    // Retrying after snapshot publication cannot duplicate the run.
    pool.with_client(db => {
      ignore(db.execute("UPDATE pipeline_workflow_event SET state='pending'"))
    })
    assert_true(run_next_workflow_event(pool, root))
    assert_eq(@runtime.list_runs(pool, actor, repo).length(), 2)
    for _ in 0..<3 {
      let latest = @runtime.list_runs(pool, actor, repo)[0]
      c.runtime.cancel_run(actor, repo, latest.number)
      ignore(run_next_workflow_event(pool, root))
    }
    assert_eq(@runtime.list_runs(pool, actor, repo).length(), 4)
    assert_false(run_next_workflow_event(pool, root))
  })
}

///|
async test "PR ready edited and closed lifecycle runs stay outside merge gates" {
  let source = @test_support.single_job_workflow.replace_all(
    old="on: workflow_dispatch",
    new="on: {pull_request: {types: [ready_for_review, edited, closed]}}",
  )
  with_merge_check_fixture(
    (pool, root, scope, actor, mr) => {
      @collaboration.edit_merge_request(pool, scope, actor, mr, "draft", "", "")
      let draft = @collaboration.require_merge_request(pool, scope, mr.number)
      @collaboration.edit_merge_request(
        pool, scope, actor, draft, "ready", "", "",
      )
      assert_true(run_next_workflow_event(pool, root))
      let ready = @collaboration.require_merge_request(pool, scope, mr.number)
      @collaboration.edit_merge_request(
        pool, scope, actor, ready, "edit", "Edited title", "Body",
      )
      assert_true(run_next_workflow_event(pool, root))
      let edited = @collaboration.require_merge_request(pool, scope, mr.number)
      @collaboration.edit_merge_request(
        pool, scope, actor, edited, "close", "", "",
      )
      assert_true(run_next_workflow_event(pool, root))
      assert_false(run_next_workflow_event(pool, root))
      let runs = @runtime.list_runs(pool, actor, protocol_repo)
      assert_eq(runs.length(), 3)
      assert_eq(runs.map(r => r.context.unwrap().event.unwrap()["action"]), [
        Json::string("closed"),
        Json::string("edited"),
        Json::string("ready_for_review"),
      ])
      assert_true(
        @collaboration.merge_checks(
          pool,
          @collaboration.require_merge_request(pool, scope, mr.number),
        ).is_empty(),
      )
      let c = merge_check_provider(pool)
      for action in ["ready_for_review", "edited", "closed"] {
        let (a, token) = claim_dag_attempt(c, provider_secret)
        assert_eq(a.job.event.get("action"), Some(Json::string(action)))
        ignore(complete_output_job(c, a, token, Map([])))
      }
    },
    workflow=source,
    required=false,
  )
}

///|
async test "a tag sharing a branch name cannot borrow that branch's secrets" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo = protocol_repo
    let dir = repo.git_dir(root)
    let source = @test_support.single_job_workflow
      .replace_all(old="on: workflow_dispatch", new="on: push")
      .replace_all(
        old="run: echo fixture",
        new="env: {TOKEN: '${{ secrets.TOKEN }}'}\n        run: 'true'",
      )
    let sha = @test_support.workflow_commit(dir, source)
    @runtime.save_secret(
      pool,
      root,
      actor,
      @repository.repository_scope(pool, actor, repo),
      "TOKEN",
      Some("branch-only"),
      "pipeline",
      ".github/workflows/build.yml",
      0L,
    )
    @repository.set_pipeline_push_enabled(pool, root, actor, repo, true)
    let update = "0".repeat(40) + " " + sha + " refs/tags/pipeline"
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "a".repeat(32),
      "prepared",
      update,
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/tags/pipeline", sha]))
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "a".repeat(32),
      "committed",
      update,
    )
    assert_true(run_next_ref_event(pool, root))
    assert_true(@runtime.list_runs(pool, actor, repo).is_empty())
    assert_true(
      @runtime.list_trigger_events(pool, actor, repo)[0].error.contains(
        "tag pushes",
      ),
    )
  })
}

///|
async test "merged PR emits an independent closed workflow at the merge commit" {
  let source = @test_support.single_job_workflow.replace_all(
    old="on: workflow_dispatch",
    new="on: {pull_request: {types: [closed]}}",
  )
  with_merge_check_fixture(
    (pool, root, scope, actor, mr) => {
      poll_merge_checks(pool, root)
      let c = merge_check_provider(pool)
      finish_merge_check(c)
      @collaboration.enqueue_merge(pool, scope, actor, mr, mr.version)
      assert_true(@collaboration.run_next_merge_job(pool, root))
      let merged = @collaboration.require_merge_request(pool, scope, mr.number)
      assert_eq(merged.status, "merged")
      for _ in 0..<5 {
        if !run_next_workflow_event(pool, root) {
          break
        }
      }
      let runs = @runtime.list_runs(pool, actor, protocol_repo)
      assert_eq(runs.length(), 2)
      assert_eq(runs[0].commit_sha, merged.merged_sha)
      assert_true(
        runs[0].context.unwrap().event.unwrap().get("pull_request")
        is Some({ "merged": true, "state": "closed", .. }),
      )
      let (a, _) = claim_dag_attempt(c, provider_secret)
      assert_eq(a.commit_sha, merged.merged_sha)
      assert_eq(a.job.event.get("action"), Some(Json::string("closed")))
    },
    workflow=source,
  )
}

///|
async test "PR lifecycle subscriptions apply captured revision path filters" {
  for
    (filters, expected) in [
      ("paths: ['unrelated/**']", 0),
      ("paths-ignore: ['README.md']", 0),
      ("paths: ['README.md']", 1),
    ] {
    let source = @test_support.single_job_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: {pull_request: {types: [edited], " + filters + "}}",
    )
    with_merge_check_fixture(
      (pool, root, scope, actor, mr) => {
        @collaboration.edit_merge_request(
          pool, scope, actor, mr, "edit", "Edited title", "Body",
        )
        assert_true(run_next_workflow_event(pool, root))
        assert_eq(
          @runtime.list_runs(pool, actor, protocol_repo).length(),
          expected,
        )
      },
      workflow=source,
      required=false,
    )
  }
}

///|
async test "PR lifecycle path filters use captured merge bases after refs move" {
  for (pattern, expected) in [("tools_sdk/**", 0), ("README.md", 1)] {
    @test_support.with_repository_test_data((pool, root) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let scope = @repository.repository_scope(pool, actor, protocol_repo)
      let dir = protocol_repo.git_dir(root)
      let source = @test_support.single_job_workflow.replace_all(
        old="on: workflow_dispatch",
        new="on: {pull_request: {types: [edited], paths: ['" + pattern + "']}}",
      )
      let base = filter_test_commit(dir, "", "master", [
        (".github/workflows/build.yml", source),
        ("tools_sdk/main.mbt", "base"),
        ("README.md", "base"),
      ])
      let head = filter_test_commit(dir, base, "feature", [
        (".github/workflows/build.yml", source),
        ("tools_sdk/main.mbt", "base"),
        ("README.md", "feature"),
      ])
      let target = filter_test_commit(dir, base, "master", [
        (".github/workflows/build.yml", source),
        ("tools_sdk/main.mbt", "target-only"),
        ("README.md", "base"),
      ])
      let mr = @collaboration.create_merge_request(
        pool, scope, dir, actor, "filter", "", "feature", "master", false,
      )
      @collaboration.edit_merge_request(
        pool, scope, actor, mr, "edit", "Edited title", "Body",
      )
      // These post-event refs reverse which paths would match. Admission must
      // use the captured head/base SHAs and exclude target-only edits.
      ignore(
        filter_test_commit(dir, head, "feature", [
          (".github/workflows/build.yml", source),
          ("tools_sdk/main.mbt", "later-source"),
          ("README.md", "base"),
        ]),
      )
      ignore(
        filter_test_commit(dir, target, "master", [
          (".github/workflows/build.yml", source),
          ("tools_sdk/main.mbt", "later-target"),
          ("README.md", "base"),
        ]),
      )
      assert_true(run_next_workflow_event(pool, root))
      let runs = @runtime.list_runs(pool, actor, protocol_repo)
      assert_eq(runs.length(), expected, msg=pattern)
      if expected == 1 {
        assert_eq(runs[0].commit_sha, head)
      }
    })
  }
}
