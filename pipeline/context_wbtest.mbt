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
    ignore(coordinator.start(id, token, 1))
    ignore(coordinator.complete(id, token, completion()))
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
    assert_eq(get_run(pool, actor, repo, run.number).context.unwrap().sha, sha)
  })
}

///|
async test "push context is taken from durable event and retained on rerun" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo = protocol_repo
    let dir = repo.git_dir(root)
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
    assert_true(run_next_push_event(pool, root))
    let run = list_runs(pool, actor, repo)[0]
    let context = run.context.unwrap()
    assert_eq(context.sha, sha)
    assert_eq(context.event_name, "push")
    assert_eq(context.head_ref, "")
    assert_eq(context.base_ref, "")
    assert_eq(run.definition.jobs[0].steps[0].env.get("EVENT"), Some("push"))
    assert_eq(run.definition.jobs[0].steps[0].env.get("SHA"), Some(sha))
    let coordinator = merge_check_provider(pool)
    finish_merge_check(coordinator)
    let again = rerun_run(pool, root, actor, repo, run.number)
    assert_eq(again.context.unwrap().event_name, "push")
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
      let run = list_runs(pool, actor, protocol_repo)[0]
      let context = run.context.unwrap()
      assert_eq(context.event_name, "pull_request")
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
    assert_true(get_run(pool, actor, repo, run.number).context is None)
    let coordinator = merge_check_provider(pool)
    finish_merge_check(coordinator)
    let again = rerun_run(pool, root, actor, repo, run.number)
    assert_true(again.context is None)
    assert_eq(again.definition_version, 1)
    let (assignment, _) = claim_dag_attempt(coordinator, provider_secret)
    assert_eq(assignment.version, 1)
    assert_eq(assignment.commit_sha, sha)
    assert_eq(assignment.job.steps[0].run, "echo fixture")
  })
}
