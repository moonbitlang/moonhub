///|
async test "single-use CI claims require the outside controller and remain consumed across restart" {
  @test_support.with_repository_test_data((pool, root) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let actor = @identity.active_user_by_name(pool, "alice")
    ignore(
      @test_support.workflow_commit(
        protocol_repo.git_dir(root),
        @test_support.single_job_workflow,
      ),
    )
    let c = Coordinator::new(pool)
    let p = c.create_provider(
      admin,
      "managed",
      "a".repeat(64),
      ["self-hosted", "linux"],
      [protocol_repo],
    )
    let original = control_registration(mode="asg")
    let schema = original.schema.copy()
    schema.push({
      name: "execution_mode",
      title: "Execution",
      kind: "choice",
      required: true,
      choices: ["linux-ci"],
      minimum: 0,
      maximum: 0,
      help: "Single-use.",
    })
    let config = { "image": "runner:v1", "execution_mode": "linux-ci" }
    ignore(
      c.register_runner("a".repeat(64), {
        ..original,
        schema,
        defaults: config,
      }),
    )
    let sync : @protocol.ProviderSyncRequest = {
      environment_protocol: None,
      version: 1,
      controller_id: "manager",
      observed_revision: "1",
      applied_revision: "1",
      status: "applied",
      schema: None,
      defaults: None,
    }
    ignore(c.sync_provider("b".repeat(64), sync))
    for _ in 0..<2 {
      ignore(
        create_run(
          pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
        ),
      )
    }
    let registration : @protocol.WorkerRegistration = {
      version: 1,
      key: "i-ci",
      token: "c".repeat(64),
    }
    let w = c.register_worker("b".repeat(64), registration)
    let wid = @protocol.parse_decimal(w.id).unwrap()
    let ready : @protocol.WorkerSyncRequest = {
      environments: None,
      version: 1,
      state: "ready",
      applied_revision: "1",
    }
    let claim = claim_request(secret="d".repeat(64))
    assert_eq(
      c.sync_worker("c".repeat(64), ready).isolation_revision,
      Some("0"),
    )
    assert_true(c.claim("c".repeat(64), claim) is None)
    try c.arm_ci_worker("c".repeat(64), "manager", wid, 1L) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("worker authorized its own isolation")
    }
    try c.arm_ci_worker("b".repeat(64), "stale", wid, 1L) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale controller armed worker")
    }
    c.arm_ci_worker("b".repeat(64), "manager", wid, 1L)
    c.save_provider_config(admin, p.id, 1L, config)
    ignore(
      c.sync_provider("b".repeat(64), {
        ..sync,
        observed_revision: "2",
        applied_revision: "2",
      }),
    )
    ignore(c.sync_worker("c".repeat(64), { ..ready, applied_revision: "2", }))
    assert_true(c.claim("c".repeat(64), claim) is None)
    c.arm_ci_worker("b".repeat(64), "manager", wid, 2L)
    let assignment = c.claim("c".repeat(64), claim).unwrap()
    assert_eq(
      c.claim("c".repeat(64), claim).unwrap().attempt_id,
      assignment.attempt_id,
    )
    let busy = c.sync_worker("c".repeat(64), {
      ..ready,
      state: "busy",
      applied_revision: "2",
    })
    assert_true(busy.draining)
    let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
    ignore(c.start(id, "d".repeat(64), 1))
    ignore(c.complete(id, "d".repeat(64), completion()))
    ignore(c.register_worker("b".repeat(64), registration))
    ignore(c.sync_worker("c".repeat(64), { ..ready, applied_revision: "2", }))
    assert_true(
      c.claim("c".repeat(64), claim_request(id="2", secret="e".repeat(64)))
      is None,
    )
    try c.arm_ci_worker("b".repeat(64), "manager", wid, 2L) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("consumed worker was rearmed")
    }
  })
}
