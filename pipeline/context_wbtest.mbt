///|
let context_workflow : String =
  #|name: Context
  #|on: [workflow_dispatch, push, pull_request]
  #|env:
  #|  REPO: ${{ github.repository }}
  #|  SHA: ${{ github.sha }}
  #|  EVENT: ${{ github.event_name }}
  #|  HEAD: ${{ github.head_ref }}
  #|  BASE: ${{ github.base_ref }}
  #|jobs:
  #|  check:
  #|    runs-on: [self-hosted, linux]
  #|    steps:
  #|      - id: check
  #|        run: echo fixture

///|
async test "manual run context and resolved env survive ref drift and snapshot rerun" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo = protocol_repo
    let dir = repo.git_dir(root)
    let sha = @test_support.workflow_commit(dir, context_workflow)
    let run = create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    let context = run.context.unwrap()
    assert_eq(context.repository, "alice/demo")
    assert_eq(context.sha, sha)
    assert_eq(context.event_name, "workflow_dispatch")
    assert_eq(context.head_ref, "")
    assert_eq(context.base_ref, "")
    let env = run.definition.jobs[0].steps[0].env
    assert_eq(env.get("SHA"), Some(sha))
    assert_eq(env.get("EVENT"), Some("workflow_dispatch"))
    assert_eq(env.get("HEAD"), Some(""))
    assert_eq(env.get("BASE"), Some(""))
    assert_eq(env.get("REPO"), Some("alice/demo"))
    assert_eq(run.workflow_source, context_workflow)
    ignore(
      @test_support.workflow_commit(dir, @test_support.single_job_workflow),
    )
    let coordinator = merge_check_provider(pool)
    let (assignment, token) = claim_dag_attempt(coordinator, provider_secret)
    assert_eq(assignment.job.steps[0].env.get("SHA"), Some(sha))
    let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
    ignore(coordinator.runtime.start(id, token, 1))
    ignore(coordinator.runtime.complete(id, token, completion()))
    let again = rerun_run(pool, root, actor, repo, run.number)
    assert_eq(ToJson::to_json(again.context.unwrap()), ToJson::to_json(context))
    assert_eq(
      ToJson::to_json(again.definition),
      ToJson::to_json(run.definition),
    )
    let (assignment, _) = claim_dag_attempt(coordinator, provider_secret)
    assert_eq(assignment.job.steps[0].env.get("SHA"), Some(sha))
    let rejected = pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_run SET context_json = '{}' WHERE id = ?",
          params=[run.id],
        ),
      )
      false
    }) catch {
      _ => true
    }
    assert_true(rejected)
    assert_eq(
      @runtime.get_run(pool, actor, repo, run.number).context.unwrap().sha,
      sha,
    )
  })
}

///|
async test "push context is taken from durable event and retained on rerun" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo = protocol_repo
    let dir = repo.git_dir(root)
    @runtime.save_variable(pool, actor, repo, "PUSH_CONFIG", "captured", 0L)
    let sha = @test_support.workflow_commit(dir, context_workflow)
    @repository.set_pipeline_push_enabled(pool, root, actor, repo, true)
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "a".repeat(32),
      "prepared",
      "\{"0".repeat(40)} \{sha} refs/heads/pushed",
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/pushed", sha]))
    @repository.record_received_transaction(
      pool,
      actor,
      repo,
      "a".repeat(32),
      "committed",
      "\{"0".repeat(40)} \{sha} refs/heads/pushed",
    )
    ignore(@test_support.merge_test_commit(dir, "pushed", sha, "later push\n"))
    assert_true(run_next_ref_event(pool, root))
    let run = @runtime.list_runs(pool, actor, repo)[0]
    let context = run.context.unwrap()
    assert_eq(context.sha, sha)
    assert_eq(context.event_name, "push")
    let event = context.event.unwrap()
    assert_eq(event.get("ref"), Some(Json::string("refs/heads/pushed")))
    assert_eq(event.get("before"), Some(Json::string("0".repeat(40))))
    assert_eq(event.get("after"), Some(Json::string(sha)))
    assert_eq(context.variables.get("PUSH_CONFIG"), Some("captured"))
    assert_true(context.inputs.is_empty())
    assert_eq(context.head_ref, "")
    assert_eq(context.base_ref, "")
    assert_eq(run.definition.jobs[0].steps[0].env.get("EVENT"), Some("push"))
    assert_eq(run.definition.jobs[0].steps[0].env.get("SHA"), Some(sha))
    let coordinator = merge_check_provider(pool)
    finish_merge_check(coordinator)
    let again = rerun_run(pool, root, actor, repo, run.number)
    assert_eq(again.context.unwrap().event_name, "push")
    assert_eq(again.context.unwrap().event, context.event)
    assert_eq(
      ToJson::to_json(again.definition),
      ToJson::to_json(run.definition),
    )
  })
}

///|
async test "MR context uses merged candidate and reruns use saved context not live MR fields" {
  with_merge_check_fixture(
    (pool, root, _, actor, mr) => {
      poll_merge_checks(pool, root)
      let run = @runtime.list_runs(pool, actor, protocol_repo)[0]
      let context = run.context.unwrap()
      assert_eq(context.event_name, "pull_request")
      let revision = @collaboration.merge_revision(pool, mr)
      assert_true(
        context.event.unwrap().get("pull_request")
        is Some(
          {
            "number": Number(number, ..),
            "head": { "sha": String(head), .. },
            "base": { "sha": String(base), .. },
            ..
          },
        ) &&
        number == mr.number.to_double() &&
        head == revision.source_sha &&
        base == revision.target_sha,
      )
      assert_eq(
        context.event.unwrap().get("action"),
        Some(Json::string("opened")),
      )
      assert_true(context.inputs.is_empty())
      assert_eq(context.sha, run.commit_sha)
      assert_true(
        context.sha != @collaboration.merge_revision(pool, mr).source_sha,
      )
      assert_eq(context.head_ref, "feature")
      assert_eq(context.base_ref, "master")
      let saved_cache = pool.with_client(client => {
        client.query_one("SELECT * FROM pipeline_cache_scope WHERE run_id=?", params=[
          run.id,
        ])
      })
      assert_eq(
        (saved_cache.get_name("scope") : String),
        "refs/pull/" + mr.id.to_string() + "/merge",
      )
      assert_eq(
        (saved_cache.get_name("base_scope") : String),
        "refs/heads/master",
      )
      let env = run.definition.jobs[0].steps[0].env
      assert_eq(env.get("SHA"), Some(run.commit_sha))
      assert_eq(env.get("HEAD"), Some("feature"))
      assert_eq(env.get("BASE"), Some("master"))
      let coordinator = merge_check_provider(pool)
      finish_merge_check(coordinator)
      // A snapshot rerun must not reconstruct context from mutable presentation
      // fields. Keep revision refs intact so the existing rerun gate stays valid.
      let dir = protocol_repo.git_dir(root)
      let revision = @collaboration.merge_revision(pool, mr)
      ignore(
        @gitops.merge_git(dir, [
          "update-ref",
          "refs/heads/renamed",
          revision.source_sha,
        ]),
      )
      pool.with_client(client => {
        ignore(
          client.execute(
            "UPDATE merge_request SET source_branch = 'renamed' WHERE id = ?",
            params=[mr.id],
          ),
        )
        ignore(
          client.execute(
            "UPDATE repository SET default_branch='renamed' WHERE id=?",
            params=[mr.repository_id],
          ),
        )
      })
      let again = rerun_run(pool, root, actor, protocol_repo, run.number)
      assert_eq(
        ToJson::to_json(again.context.unwrap()),
        ToJson::to_json(context),
      )
      assert_eq(
        again.definition.jobs[0].steps[0].env.get("HEAD"),
        Some("feature"),
      )
      assert_eq(again.source_branch, "feature")
      let again_cache = pool.with_client(client => {
        client.query_one("SELECT * FROM pipeline_cache_scope WHERE run_id=?", params=[
          again.id,
        ])
      })
      for name in ["scope", "base_scope", "default_scope"] {
        assert_eq(
          (again_cache.get_name(name) : String),
          (saved_cache.get_name(name) : String),
        )
      }
    },
    workflow=context_workflow,
  )
}

///|
async test "legacy contextless snapshot can still be read claimed and rerun" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo = protocol_repo
    let scope = @repository.repository_scope(pool, actor, repo)
    let dir = repo.git_dir(root)
    let sha = @test_support.workflow_commit(
      dir, @test_support.single_job_workflow,
    )
    let pin = "refs/moonhub/pipelines/legacy-contextless"
    ignore(@gitops.merge_git(dir, ["update-ref", pin, sha]))
    let run = pool.with_client(client => {
      client.with_transaction(tx => {
        insert_run_snapshot(
          tx,
          scope.id,
          actor.id,
          ".github/workflows/build.yml",
          "Legacy",
          "pipeline",
          sha,
          pin,
          @test_support.single_job_workflow,
          @workflow.parse(@test_support.single_job_workflow),
          definition_version=1,
        )
      })
    })
    assert_true(@runtime.get_run(pool, actor, repo, run.number).context is None)
    let coordinator = merge_check_provider(pool)
    finish_merge_check(coordinator)
    let again = rerun_run(pool, root, actor, repo, run.number)
    assert_true(again.context is None)
    assert_eq(again.definition_version, 1)
    let (assignment, _) = claim_dag_attempt(coordinator, provider_secret)
    assert_eq(assignment.version, @protocol.run_attempt_assignment_version)
    assert_eq(assignment.job.context.get("dispatch_context"), Some("false"))
    assert_eq(assignment.commit_sha, sha)
    assert_eq(assignment.job.steps[0].run, "echo fixture")
  })
}

///|
async test "PR concurrency groups use the captured PR number across source pushes" {
  with_merge_check_fixture(
    (pool, root, scope, actor, mr) => {
      poll_merge_checks(pool, root)
      let original = @runtime.list_runs(pool, actor, protocol_repo)[0]
      let old_event = original.context.unwrap().event.unwrap()
      let key = pool.with_client(c => {
        (
          c
          .query_one(
            "SELECT group_key FROM pipeline_run_schedule WHERE run_id=?",
            params=[original.id],
          )
          .get_name("group_key") : String)
      })
      assert_eq(key, "ci-" + mr.number.to_string())
      let coordinator = merge_check_provider(pool)
      let first = coordinator.runtime
        .claim(provider_secret, claim_request())
        .unwrap()
      assert_eq(first.job.event, old_event)
      let id = @protocol.parse_decimal(first.attempt_id).unwrap()
      ignore(coordinator.runtime.start(id, attempt_secret, 1))
      ignore(coordinator.runtime.complete(id, attempt_secret, completion()))
      let dir = protocol_repo.git_dir(root)
      let head = merge_check_commit(
        dir,
        "feature",
        @gitops.branch_sha(dir, "feature"),
        "changed head\n",
      )
      poll_merge_checks(pool, root)
      let updated = @collaboration.require_merge_request(pool, scope, mr.number)
      @collaboration.prepare_merge_checks(pool, scope, updated, actor~)
      poll_merge_checks(pool, root)
      let fresh = @runtime.list_runs(pool, actor, protocol_repo)[0]
      assert_true(fresh.id != original.id)
      assert_eq(
        pool.with_client(c => {
          (
            c
            .query_one(
              "SELECT group_key FROM pipeline_run_schedule WHERE run_id=?",
              params=[fresh.id],
            )
            .get_name("group_key") : String)
        }),
        key,
      )
      assert_true(
        fresh.context.unwrap().event.unwrap().get("pull_request")
        is Some({ "head": { "sha": String(sha), .. }, .. }) &&
        sha == head,
      )
      assert_eq(
        @runtime.get_run(pool, actor, protocol_repo, original.number).context.unwrap().event,
        Some(old_event),
      )
    },
    workflow=context_workflow +
      "\nconcurrency: ci-${{ github.event.pull_request.number || github.run_id }}\n",
  )
}
