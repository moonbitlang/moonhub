///|
let deployment_workflow : String =
  #|on: workflow_dispatch
  #|jobs:
  #|  build:
  #|    runs-on: self-hosted
  #|    steps: [{id: build, run: echo build}]
  #|  deploy:
  #|    needs: build
  #|    environment: production
  #|    concurrency: deploy
  #|    runs-on: self-hosted
  #|    steps: [{id: deploy, run: echo deploy, env: {TOKEN: '${{ secrets.TOKEN }}'}}]
  #|  stage:
  #|    needs: build
  #|    environment: staging
  #|    runs-on: self-hosted
  #|    steps: [{id: stage, run: echo stage, env: {TOKEN: '${{ secrets.TOKEN }}'}}]

///|
async fn with_deployment_fixture(
  f : async (
    PipelineFixture,
    @database.Database,
    String,
    @runtime.Run,
    Ref[Int64],
  ) -> Unit,
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let clock = Ref(1700000000000L)
    let c = test_services(pool, clock=() => clock.val)
    ignore(
      c.runtime.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "default",
        provider_secret,
        ["self-hosted", "linux"],
        [protocol_repo],
      ),
    )
    c.runtime.save_deployment_environment(
      actor,
      protocol_repo,
      "production",
      0L,
      [actor.id],
    )
    c.runtime.save_deployment_environment(actor, protocol_repo, "staging", 0L, [])
    @runtime.save_variable(
      pool, actor, protocol_repo, "REGION", "repository", 0L,
    )
    for name in ["production", "staging"] {
      @runtime.save_deployment_value(
        pool,
        actor,
        protocol_repo,
        name,
        "REGION",
        Some(name),
        0L,
        secret=false,
      )
      @runtime.save_deployment_value(
        pool,
        actor,
        protocol_repo,
        name,
        "TOKEN",
        Some(name + "-secret"),
        0L,
        secret=true,
      )
    }
    ignore(
      @test_support.workflow_commit(
        protocol_repo.git_dir(root),
        deployment_workflow,
      ),
    )
    @runtime.save_secret(
      pool,
      root,
      actor,
      @runtime.require_run_author(pool, actor, protocol_repo),
      "TOKEN",
      Some("repository-secret"),
      "pipeline",
      ".github/workflows/build.yml",
      0L,
    )
    let run = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    f(c, pool, root, run, clock)
  })
}

///|
fn deployment_secret(
  c : PipelineFixture,
  a : @protocol.Assignment,
  token : String,
) -> String raise {
  let id = @protocol.parse_decimal(a.attempt_id).unwrap()
  ignore(c.runtime.start(id, token, 1, execution_id="1".repeat(32)))
  ignore(
    c.runtime.update_step(id, token, {
      version: 1,
      step_id: a.job.steps[0].id,
      state: "running",
      exit_code: 0,
    }),
  )
  c.runtime.step_secrets(id, token, {
    version: 1,
    execution_id: "1".repeat(32),
    step_id: a.job.steps[0].id,
  }).env
  .get("TOKEN")
  .unwrap()
}

///|
async test "deployment waits after dependencies without capacity or credentials and scopes values" {
  with_deployment_fixture((c, pool, _, run, clock) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    assert_true(
      @runtime.job_deployments(pool, actor, protocol_repo, run.number).is_empty(),
    )
    let build = c.runtime.claim(provider_secret, claim_request()).unwrap()
    assert_eq(build.job.variables.get("REGION"), Some("repository"))
    ignore(complete_output_job(c, build, attempt_secret, Map([])))
    let pending = @runtime.job_deployments(
        pool,
        actor,
        protocol_repo,
        run.number,
      )[0]
    assert_eq(pending.state, "pending")
    assert_true(
      c.runtime.queue_reasons(actor, protocol_repo, run.number).get("deploy")
      is Some(WaitingApproval),
    )
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one(
            "SELECT count(*) AS n FROM pipeline_concurrency_slot WHERE job_id=?",
            params=[pending.job_id],
          )
          .get_name("n") : Int64),
        0L,
      )
      assert_eq(
        (
          client
          .query_one(
            "SELECT count(*) AS n FROM pipeline_job_attempt WHERE job_id=?",
            params=[pending.job_id],
          )
          .get_name("n") : Int64),
        0L,
      )
    })
    let stage = c.runtime
      .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
      .unwrap()
    assert_eq(stage.job.id, "stage")
    assert_eq(stage.job.variables.get("REGION"), Some("staging"))
    assert_eq(deployment_secret(c, stage, "c".repeat(64)), "staging-secret")
    ignore(complete_output_job(c, stage, "c".repeat(64), Map([])))
    let restarted = test_services(pool, clock=() => clock.val)
    assert_true(
      restarted.runtime.claim(
        provider_secret,
        claim_request(id="3", secret="d".repeat(64)),
      )
      is None,
    )
    try
      restarted.runtime.review_deployment(
        @identity.active_user_by_name(pool, "admin"),
        protocol_repo,
        run.number,
        pending.job_id,
        pending.environment_id,
        pending.policy_version,
        "approved",
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("unlisted administrator bypassed approval")
    }
    restarted.runtime.review_deployment(
      actor,
      protocol_repo,
      run.number,
      pending.job_id,
      pending.environment_id,
      pending.policy_version,
      "approved",
    )
    restarted.runtime.review_deployment(
      actor,
      protocol_repo,
      run.number,
      pending.job_id,
      pending.environment_id,
      pending.policy_version,
      "approved",
    )
    let deploy = restarted.runtime
      .claim(provider_secret, claim_request(id="4", secret="e".repeat(64)))
      .unwrap()
    assert_eq(deploy.job.id, "deploy")
    assert_eq(deploy.job.variables.get("REGION"), Some("production"))
    assert_false(deploy.to_json().stringify().contains("production-secret"))
    assert_eq(
      deployment_secret(restarted, deploy, "e".repeat(64)),
      "production-secret",
    )
    let id = @protocol.parse_decimal(deploy.attempt_id).unwrap()
    let config = @runtime.list_deployment_environments(
        pool, actor, protocol_repo,
      )[0]
    @runtime.save_deployment_value(
      pool,
      actor,
      protocol_repo,
      "production",
      "TOKEN",
      None,
      config.secrets["TOKEN"],
      secret=true,
    )
    try
      ignore(
        restarted.runtime.step_secrets(id, "e".repeat(64), {
          version: 1,
          execution_id: "1".repeat(32),
          step_id: "deploy",
        }),
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("deleted environment secret fell back to its cached credential")
    }
    ignore(
      restarted.runtime.append_log(id, "e".repeat(64), {
        ..log_request(1L, "production-secret\n"),
        step_id: "deploy",
      }),
    )
    ignore(
      restarted.runtime.update_step(id, "e".repeat(64), {
        version: 1,
        step_id: "deploy",
        state: "success",
        exit_code: 0,
      }),
    )
    ignore(restarted.runtime.complete(id, "e".repeat(64), completion(last=1L)))
    let log = restarted.runtime.read_log_page(
      actor,
      protocol_repo,
      run.number,
      id,
    )
    assert_false(
      ToJson::to_json(log.chunks).stringify().contains("production-secret"),
    )
    assert_eq(
      @runtime.job_deployments(pool, actor, protocol_repo, run.number)[0].reviews.length(),
      1,
    )
  })
}

///|
async test "deployment policy revisions invalidate approvals and live credentials" {
  with_deployment_fixture((c, pool, _, run, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    ignore(
      complete_output_job(
        c,
        c.runtime.claim(provider_secret, claim_request()).unwrap(),
        attempt_secret,
        Map([]),
      ),
    )
    let old = @runtime.job_deployments(pool, actor, protocol_repo, run.number)[0]
    c.runtime.save_deployment_environment(
      actor,
      protocol_repo,
      "production",
      1L,
      [actor.id],
    )
    try
      c.runtime.review_deployment(
        actor,
        protocol_repo,
        run.number,
        old.job_id,
        old.environment_id,
        old.policy_version,
        "approved",
      )
    catch {
      @runtime.Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale policy approved")
    }
    let current = @runtime.job_deployments(
        pool,
        actor,
        protocol_repo,
        run.number,
      )[0]
    assert_eq(current.policy_version, 2L)
    c.runtime.review_deployment(
      actor,
      protocol_repo,
      run.number,
      current.job_id,
      current.environment_id,
      current.policy_version,
      "approved",
    )
    let deploy = c.runtime
      .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
      .unwrap()
    assert_eq(deployment_secret(c, deploy, "c".repeat(64)), "production-secret")
    c.runtime.save_deployment_environment(
      actor,
      protocol_repo,
      "production",
      2L,
      [actor.id],
    )
    try
      ignore(
        c.runtime.step_secrets(
          @protocol.parse_decimal(deploy.attempt_id).unwrap(),
          "c".repeat(64),
          { version: 1, execution_id: "1".repeat(32), step_id: "deploy", },
        ),
      )
    catch {
      @runtime.Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("revoked approval fetched credentials")
    }
  })
}

///|
async test "environment rejection and cancellation are durable and reruns retain public snapshots only" {
  with_deployment_fixture((c, pool, root, run, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    ignore(
      complete_output_job(
        c,
        c.runtime.claim(provider_secret, claim_request()).unwrap(),
        attempt_secret,
        Map([]),
      ),
    )
    let pending = @runtime.job_deployments(
        pool,
        actor,
        protocol_repo,
        run.number,
      )[0]
    c.runtime.review_deployment(
      actor,
      protocol_repo,
      run.number,
      pending.job_id,
      pending.environment_id,
      pending.policy_version,
      "rejected",
    )
    assert_eq(
      @runtime.job_deployments(pool, actor, protocol_repo, run.number)[0].state,
      "rejected",
    )
    let stage = c.runtime
      .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
      .unwrap()
    ignore(complete_output_job(c, stage, "c".repeat(64), Map([])))
    let config = @runtime.list_deployment_environments(
        pool, actor, protocol_repo,
      )[0]
    @runtime.save_deployment_value(
      pool,
      actor,
      protocol_repo,
      "production",
      "REGION",
      Some("changed"),
      config.variable_versions["REGION"],
      secret=false,
    )
    @runtime.save_deployment_value(
      pool,
      actor,
      protocol_repo,
      "production",
      "TOKEN",
      Some("rotated-secret"),
      config.secrets["TOKEN"],
      secret=true,
    )
    let retry = rerun_run(
      pool,
      root,
      actor,
      protocol_repo,
      run.number,
      failed_only=true,
    )
    let gate = @runtime.job_deployments(
        pool,
        actor,
        protocol_repo,
        retry.number,
      )[0]
    assert_eq(gate.state, "pending")
    assert_false(gate.job_id == pending.job_id)
    c.runtime.review_deployment(
      actor,
      protocol_repo,
      retry.number,
      gate.job_id,
      gate.environment_id,
      gate.policy_version,
      "approved",
    )
    let deploy = c.runtime
      .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
      .unwrap()
    assert_eq(deploy.job.variables.get("REGION"), Some("production"))
    assert_eq(deployment_secret(c, deploy, "d".repeat(64)), "rotated-secret")
    ignore(complete_output_job(c, deploy, "d".repeat(64), Map([])))
    let full = rerun_run(pool, root, actor, protocol_repo, run.number)
    ignore(
      complete_output_job(
        c,
        c.runtime
        .claim(provider_secret, claim_request(id="4", secret="e".repeat(64)))
        .unwrap(),
        "e".repeat(64),
        Map([]),
      ),
    )
    c.runtime.cancel_run(actor, protocol_repo, full.number)
    let cancelled = @runtime.job_deployments(
        pool,
        actor,
        protocol_repo,
        full.number,
      )[0]
    assert_eq(cancelled.state, "cancelled")
    assert_true(cancelled.reviews[0] is { "decision": "cancelled", .. })
  })
}

///|
async test "deleting and recreating an environment cannot rebind saved runs" {
  with_deployment_fixture((c, pool, root, run, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    c.runtime.cancel_run(actor, protocol_repo, run.number)
    c.runtime.delete_deployment_environment(
      actor, protocol_repo, "production", 1L,
    )
    c.runtime.save_deployment_environment(
      actor,
      protocol_repo,
      "production",
      0L,
      [],
    )
    let retry = rerun_run(pool, root, actor, protocol_repo, run.number)
    ignore(
      complete_output_job(
        c,
        c.runtime.claim(provider_secret, claim_request()).unwrap(),
        attempt_secret,
        Map([]),
      ),
    )
    let jobs = @runtime.list_jobs(pool, actor, protocol_repo, retry.number)
    assert_true(jobs[1].conclusion is Some(Failure))
    assert_true(jobs[1].scheduling_error.contains("no longer available"))
  })
}

///|
async test "queued approval rechecks reviewer membership before consuming capacity" {
  with_deployment_fixture((c, pool, _, run, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let reviewer = @identity.active_user_by_name(pool, "admin")
    ignore(
      complete_output_job(
        c,
        c.runtime.claim(provider_secret, claim_request()).unwrap(),
        attempt_secret,
        Map([]),
      ),
    )
    c.runtime.save_deployment_environment(
      actor,
      protocol_repo,
      "production",
      1L,
      [reviewer.id],
    )
    let pending = @runtime.job_deployments(
        pool,
        actor,
        protocol_repo,
        run.number,
      )[0]
    c.runtime.review_deployment(
      reviewer,
      protocol_repo,
      run.number,
      pending.job_id,
      pending.environment_id,
      pending.policy_version,
      "approved",
    )
    pool.with_client(client => {
      ignore(
        client.execute("UPDATE user SET is_site_admin=0 WHERE id=?", params=[
          reviewer.id,
        ]),
      )
    })
    let claimed = c.runtime
      .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
      .unwrap()
    assert_eq(claimed.job.id, "stage")
    assert_eq(
      @runtime.job_deployments(pool, actor, protocol_repo, run.number)[0].state,
      "pending",
    )
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one(
            "SELECT count(*) AS n FROM pipeline_concurrency_slot WHERE job_id=?",
            params=[pending.job_id],
          )
          .get_name("n") : Int64),
        0L,
      )
    })
  })
}
