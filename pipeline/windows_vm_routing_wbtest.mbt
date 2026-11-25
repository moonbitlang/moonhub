///|
async test "Windows VM claims fence the guest and keep existing Windows selectors at ordinary privilege" {
  @test_support.with_repository_test_data((pool, root) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let actor = @identity.active_user_by_name(pool, "alice")
    let c = test_services(pool).runtime
    let labels = ["self-hosted", "windows", "x64", "windows-2025", "windows-vm"]
    let container = c.create_provider(
      admin,
      "container",
      "1".repeat(64),
      labels,
      [protocol_repo],
    )
    let vm = c.create_provider(admin, "managed", "2".repeat(64), labels, [
      protocol_repo,
    ])
    let registration = control_registration(mode="asg")
    let field : @protocol.ConfigField = {
      name: "execution_mode",
      title: "Execution mode",
      kind: "choice",
      required: true,
      choices: ["windows-vm"],
      minimum: 0,
      maximum: 0,
      help: "",
    }
    let schema = registration.schema +
      [
        field,
        {
          ..field,
          name: "windows_vm_default",
          choices: ["disabled", "enabled"],
        },
      ]
    let config = {
      "image": "runner:v1",
      "execution_mode": "windows-vm",
      "windows_vm_default": "disabled",
    }
    ignore(
      c.register_runner("2".repeat(64), {
        ..registration,
        schema,
        defaults: config,
      }),
    )
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
        "windows-2025", "[self-hosted, windows, x64, windows-2025, windows-vm]",
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
    let token = "b".repeat(64)
    assert_eq(c.sync_provider(token, sync).queued_jobs, 1)
    let vm_worker = "3".repeat(64)
    let worker = c.register_worker(token, {
      version: 1,
      key: "i-one",
      token: vm_worker,
    })
    let worker_id = @protocol.parse_decimal(worker.id).unwrap()
    let ready : @protocol.WorkerSyncRequest = {
      version: 1,
      state: "ready",
      applied_revision: "1",
      environments: None,
    }
    ignore(c.sync_worker(vm_worker, ready))
    let request = {
      ..claim_request(secret="4".repeat(64)),
      runner_os: Some("windows"),
    }
    assert_true(c.claim(vm_worker, request) is None)
    let ordinary = { ..request, attempt_token: "5".repeat(64), }
    let taken = c.claim("1".repeat(64), ordinary).unwrap()
    assert_false(taken.job.runs_on.contains("windows-vm"))
    let attempt = @protocol.parse_decimal(taken.attempt_id).unwrap()
    ignore(c.start(attempt, ordinary.attempt_token, 1))
    ignore(c.complete(attempt, ordinary.attempt_token, completion()))
    assert_true(
      c.claim("1".repeat(64), {
        ..ordinary,
        request_id: "a".repeat(32),
        attempt_token: "a".repeat(64),
      })
      is None,
    )
    c.arm_ci_worker(token, "manager", worker_id, 1L)
    let privileged = c.claim(vm_worker, request).unwrap()
    assert_true(privileged.job.runs_on.contains("windows-vm"))
    assert_eq(
      c.claim(vm_worker, request).unwrap().attempt_id,
      privileged.attempt_id,
    )
    assert_true(c.sync_worker(vm_worker, { ..ready, state: "busy", }).draining)
    let attempt = @protocol.parse_decimal(privileged.attempt_id).unwrap()
    ignore(c.start(attempt, request.attempt_token, 1))
    ignore(c.complete(attempt, request.attempt_token, completion()))

    ignore(
      @test_support.workflow_commit(
        protocol_repo.git_dir(root),
        source.replace_all(old="[self-hosted, linux]", new="windows-2025"),
      ),
    )
    ignore(
      create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      ),
    )
    assert_eq(c.sync_provider(token, sync).queued_jobs, 0)
    c.set_provider_paused(admin, container.id, true)
    config["windows_vm_default"] = "enabled"
    c.save_provider_config(admin, vm.id, 1L, config)
    let sync = { ..sync, observed_revision: "2", applied_revision: "2", }
    assert_eq(c.sync_provider(token, sync).queued_jobs, 1)
    let request = {
      ..request,
      request_id: "2".repeat(32),
      attempt_token: "6".repeat(64),
    }
    assert_true(c.claim(vm_worker, request) is None)
    let worker = c.register_worker(token, {
      version: 1,
      key: "i-two",
      token: "7".repeat(64),
    })
    let worker_id = @protocol.parse_decimal(worker.id).unwrap()
    ignore(c.sync_worker("7".repeat(64), { ..ready, applied_revision: "2", }))
    c.arm_ci_worker(token, "manager", worker_id, 2L)
    assert_false(
      c.claim("7".repeat(64), request).unwrap().job.runs_on.contains(
        "windows-vm",
      ),
    )
  })
}
