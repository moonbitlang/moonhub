///|
async test "macOS ASG routes only matching Mac jobs and consumes each isolated worker once" {
  @test_support.with_repository_test_data((pool, root) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let actor = @identity.active_user_by_name(pool, "alice")
    let c = test_services(pool).runtime
    let labels = ["self-hosted", "macos", "arm64", "macos-15", "macos-vm"]
    let provider = c.create_provider(admin, "managed", "1".repeat(64), labels, [
      protocol_repo,
    ])
    ignore(
      c.create_provider(admin, "local", "2".repeat(64), labels, [protocol_repo]),
    )
    let registration = control_registration(mode="asg")
    let field : @protocol.ConfigField = {
      name: "execution_mode",
      title: "Execution mode",
      kind: "choice",
      required: true,
      choices: ["macos-vm"],
      minimum: 0,
      maximum: 0,
      help: "",
    }
    let request = {
      ..registration,
      schema: registration.schema + [field],
      defaults: { "image": "runner:v1", "execution_mode": "macos-vm" },
    }
    try
      ignore(c.register_runner("1".repeat(64), { ..request, mode: "tart", }))
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("Tart provider enrolled the ASG execution profile")
    }
    ignore(c.register_runner("1".repeat(64), request))
    try
      c.set_provider_labels(admin, provider.id, ["self-hosted", "macos", "x64"])
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("ARM64-only provider advertised x64")
    }
    let sync : @protocol.ProviderSyncRequest = {
      version: 1,
      controller_id: "manager",
      status: "applied",
      observed_revision: "1",
      applied_revision: "1",
      schema: None,
      defaults: None,
      environment_protocol: None,
    }
    let source = @test_support.single_job_workflow
    for
      selector in [
        "[self-hosted]", "windows-2025", "macos-14", "[self-hosted, macos, arm64, macos-vm]",
      ] {
      ignore(
        @test_support.workflow_commit(
          protocol_repo.git_dir(root),
          source.replace_all(old="[self-hosted, linux]", new=selector),
        ),
      )
      ignore(
        create_run(
          pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
        ),
      )
    }
    let token = registration.provider_token
    let worker = "3".repeat(64)
    let claim = {
      ..claim_request(secret="4".repeat(64)),
      runner_os: Some("macos"),
    }
    assert_true(c.claim("2".repeat(64), claim) is None)
    assert_eq(c.sync_provider(token, sync).queued_jobs, 1)
    let register = c.register_worker(token, {
      version: 1,
      key: "i-mac-one",
      token: worker,
    })
    let worker_id = @protocol.parse_decimal(register.id).unwrap()
    let ready : @protocol.WorkerSyncRequest = {
      version: 1,
      state: "ready",
      applied_revision: "1",
      environments: None,
    }
    ignore(c.sync_worker(worker, ready))
    assert_true(c.claim(worker, claim) is None)
    c.arm_ci_worker(token, "manager", worker_id, 1L)
    let assignment = c.claim(worker, claim).unwrap()
    assert_true(assignment.job.runs_on.contains("macos-vm"))
    assert_eq(c.claim(worker, claim).unwrap().attempt_id, assignment.attempt_id)
    let attempt = @protocol.parse_decimal(assignment.attempt_id).unwrap()
    ignore(c.start(attempt, claim.attempt_token, 1))
    ignore(c.complete(attempt, claim.attempt_token, completion()))

    ignore(
      @test_support.workflow_commit(
        protocol_repo.git_dir(root),
        source.replace_all(old="[self-hosted, linux]", new="macos-15"),
      ),
    )
    ignore(
      create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      ),
    )
    assert_eq(c.sync_provider(token, sync).queued_jobs, 1)
    let next = {
      ..claim,
      request_id: "2".repeat(32),
      attempt_token: "5".repeat(64),
    }
    assert_true(c.claim(worker, next) is None)
    let fresh = "6".repeat(64)
    let register = c.register_worker(token, {
      version: 1,
      key: "i-mac-two",
      token: fresh,
    })
    ignore(c.sync_worker(fresh, ready))
    assert_true(c.claim(fresh, next) is None)
    c.arm_ci_worker(
      token,
      "manager",
      @protocol.parse_decimal(register.id).unwrap(),
      1L,
    )
    assert_true(c.claim(fresh, next).unwrap().job.runs_on.contains("macos-15"))
  })
}
