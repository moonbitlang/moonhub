///|
fn control_registration(
  mode~ : String = "docker",
) -> @protocol.RegisterProviderRequest {
  {
    version: 1,
    name: "managed",
    mode,
    provider_token: "b".repeat(64),
    schema: [
      {
        name: "image",
        title: "Runner image",
        kind: "text",
        required: true,
        choices: [],
        minimum: 0,
        maximum: 0,
        help: "New tasks only.",
      },
    ],
    defaults: { "image": "runner:v1" },
  }
}

///|
async test "managed registration is retry safe and configuration survives restart" {
  @test_support.with_repository_test_data((pool, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let c = Coordinator::new(pool)
    let provider = c.create_provider(
      admin,
      "managed",
      "a".repeat(64),
      ["self-hosted", "linux"],
      [],
    )
    let request = control_registration()
    let first = c.register_runner("a".repeat(64), request)
    assert_eq(first.id, provider.id.to_string())
    assert_eq(first.config_revision, "1")
    c.save_provider_config(admin, provider.id, 1L, { "image": "runner:v2" })
    let retried = c.register_runner("a".repeat(64), request)
    assert_eq(retried.config_revision, "2")
    assert_eq(retried.config.get("image"), Some("runner:v2"))
    try
      c.register_runner("a".repeat(64), {
        ..request,
        provider_token: "c".repeat(64),
      })
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("registration credential stole an existing identity")
    }
    try
      c.save_provider_config(admin, provider.id, 1L, { "image": "runner:v3" })
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale save overwrote configuration")
    }
    try ignore(c.claim("a".repeat(64), claim_request())) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("registration token retained execution permission")
    }
    let cfg = c.provider_control(admin, provider.id)
    assert_eq(cfg.snapshot.config.get("image"), Some("runner:v2"))
  })
}

///|
async test "controller lease excludes a second manager and acknowledgements are bounded" {
  @test_support.with_repository_test_data((pool, _) => {
    let clock = Ref(1700000000000L)
    let c = Coordinator::new(pool, clock=() => clock.val)
    let admin = @identity.active_user_by_name(pool, "admin")
    ignore(
      c.create_provider(
        admin,
        "managed",
        "a".repeat(64),
        ["self-hosted", "linux"],
        [],
      ),
    )
    ignore(c.register_runner("a".repeat(64), control_registration(mode="asg")))
    let request : @protocol.ProviderSyncRequest = {
      version: 1,
      controller_id: "first",
      observed_revision: "1",
      applied_revision: "1",
      status: "applied",
      schema: None,
      defaults: None,
    }
    ignore(c.sync_provider("b".repeat(64), request))
    try
      c.sync_provider("b".repeat(64), { ..request, controller_id: "second", })
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("two managers held the same lease")
    }
    clock.val += 60001L
    ignore(
      c.sync_provider("b".repeat(64), { ..request, controller_id: "second", }),
    )
    try
      c.sync_provider("b".repeat(64), {
        ..request,
        controller_id: "second",
        applied_revision: "2",
      })
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("acknowledged future configuration")
    }
  })
}

///|
async test "worker identities share grants but claim independently and drain atomically" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    ignore(
      @test_support.workflow_commit(
        repo.git_dir(root),
        @test_support.single_job_workflow,
      ),
    )
    let actor = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let c = Coordinator::new(pool)
    let provider = c.create_provider(
      admin,
      "managed",
      "a".repeat(64),
      ["self-hosted", "linux"],
      [repo],
    )
    ignore(c.register_runner("a".repeat(64), control_registration()))
    ignore(
      c.sync_provider("b".repeat(64), {
        version: 1,
        controller_id: "manager",
        observed_revision: "1",
        applied_revision: "1",
        status: "applied",
        schema: None,
        defaults: None,
      }),
    )
    ignore(
      create_run(
        pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
      ),
    )
    ignore(
      create_run(
        pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
      ),
    )
    let first = c.register_worker("b".repeat(64), {
      version: 1,
      key: "one",
      token: "c".repeat(64),
    })
    ignore(
      c.register_worker("b".repeat(64), {
        version: 1,
        key: "two",
        token: "d".repeat(64),
      }),
    )
    let ready : @protocol.WorkerSyncRequest = {
      version: 1,
      state: "ready",
      applied_revision: "1",
    }
    ignore(c.sync_worker("c".repeat(64), ready))
    ignore(c.sync_worker("d".repeat(64), ready))
    let claim : @protocol.ClaimRequest = {
      version: 1,
      runner_os: None,
      request_id: "1".repeat(32),
      attempt_token: "e".repeat(64),
    }
    c.save_provider_config(admin, provider.id, 1L, { "image": "runner:v2" })
    assert_true(c.claim("c".repeat(64), claim) is None)
    ignore(c.sync_worker("c".repeat(64), { ..ready, applied_revision: "2", }))
    assert_true(c.claim("c".repeat(64), claim) is None)
    ignore(
      c.sync_provider("b".repeat(64), {
        version: 1,
        controller_id: "manager",
        observed_revision: "2",
        applied_revision: "2",
        status: "applied",
        schema: None,
        defaults: None,
      }),
    )
    assert_true(
      c.claim("d".repeat(64), { ..claim, request_id: "0".repeat(32), }) is None,
    )
    ignore(c.sync_worker("d".repeat(64), { ..ready, applied_revision: "2", }))
    try
      c.claim("c".repeat(64), { ..claim, attempt_token: "a".repeat(64), })
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("registration credential became an attempt credential")
    }
    let a = c.claim("c".repeat(64), claim).unwrap()
    assert_eq(c.claim("c".repeat(64), claim).unwrap().attempt_id, a.attempt_id)
    let b = c
      .claim("d".repeat(64), {
        ..claim,
        runner_os: None,
        request_id: "2".repeat(32),
        attempt_token: "f".repeat(64),
      })
      .unwrap()
    assert_true(a.attempt_id != b.attempt_id)
    try c.sync_worker("c".repeat(64), ready) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("worker skipped active task")
    }
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.start(id, "e".repeat(64), 1))
    ignore(
      c.complete(id, "e".repeat(64), {
        version: 1,
        conclusion: "success",
        last_log_sequence: "0",
        outputs: Map([]),
      }),
    )
    c.drain_worker("b".repeat(64), @protocol.parse_decimal(first.id).unwrap())
    let drained = c.sync_worker("c".repeat(64), ready)
    assert_true(drained.draining)
    assert_true(
      c.claim("c".repeat(64), {
        ..claim,
        runner_os: None,
        request_id: "3".repeat(32),
        attempt_token: "1".repeat(64),
      })
      is None,
    )
    let control = c.provider_control(admin, provider.id)
    let worker = control.snapshot.workers[0]
    assert_eq(worker.state, "drained")
    assert_eq(worker.active_attempts, 0)
    c.revoke_provider(admin, provider.id)
    try c.sync_worker("d".repeat(64), { ..ready, state: "busy", }) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("revoked worker still authorized")
    }
  })
}

///|
async test "expired workers are terminal and enrollment retries outlive bounded history" {
  @test_support.with_repository_test_data((pool, _) => {
    let clock = Ref(1700000000000L)
    let c = Coordinator::new(pool, clock=() => clock.val)
    let admin = @identity.active_user_by_name(pool, "admin")
    let provider = c.create_provider(
      admin,
      "managed",
      "a".repeat(64),
      ["self-hosted", "linux"],
      [],
    )
    ignore(c.register_runner("a".repeat(64), control_registration()))
    try
      c.register_worker("b".repeat(64), {
        version: 1,
        key: "bad",
        token: "a".repeat(64),
      })
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("registration credential became a worker credential")
    }
    let registration : @protocol.WorkerRegistration = {
      version: 1,
      key: "oldest",
      token: "c".repeat(64),
    }
    let worker = c.register_worker("b".repeat(64), registration)
    clock.val += 180001L
    let snapshot = c.sync_provider("b".repeat(64), {
      version: 1,
      controller_id: "manager",
      observed_revision: "1",
      applied_revision: "1",
      status: "applied",
      schema: None,
      defaults: None,
    })
    assert_eq(snapshot.workers[0].state, "failed")
    assert_true(snapshot.workers[0].draining)
    try
      c.sync_worker("c".repeat(64), {
        version: 1,
        state: "ready",
        applied_revision: "1",
      })
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("expired worker resumed task claims")
    }
    pool.with_client(client => {
      for i = 0; i < 101; i = i + 1 {
        ignore(
          client.execute(
            "INSERT INTO pipeline_worker(provider_id,worker_key,token_hash,state,last_seen_ms,idle_since_ms) VALUES(?,?,?,'drained',0,0)",
            params=[
              provider.id,
              "history-" + i.to_string(),
              "test-hash-" + i.to_string(),
            ],
          ),
        )
      }
    })
    let control = c.provider_control(admin, provider.id)
    assert_eq(control.snapshot.workers.length(), 100)
    assert_true(!control.snapshot.workers.any(w => w.key == "oldest"))
    let retry = c.register_worker("b".repeat(64), registration)
    assert_eq(retry.id, worker.id)
    assert_eq(retry.state, "failed")
  })
}

///|
async test "controller schema extension preserves configuration and requires the current lease" {
  let legacy_json =
    #|{"version":1,"controller_id":"manager","observed_revision":"2","applied_revision":"2","status":"applied"}
  let legacy : @protocol.ProviderSyncRequest = @json.from_json(
    @json.parse(legacy_json),
  )
  assert_true(legacy.schema is None)
  assert_true(legacy.defaults is None)
  @test_support.with_repository_test_data((pool, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let c = Coordinator::new(pool)
    let provider = c.create_provider(
      admin,
      "managed",
      "a".repeat(64),
      ["self-hosted", "linux"],
      [],
    )
    let registration = control_registration(mode="asg")
    ignore(c.register_runner("a".repeat(64), registration))
    c.save_provider_config(admin, provider.id, 1L, { "image": "runner:saved" })
    ignore(c.sync_provider("b".repeat(64), legacy))
    let standby : @protocol.ConfigField = {
      name: "standby_workers",
      title: "Standby workers",
      kind: "integer",
      required: true,
      choices: [],
      minimum: 0,
      maximum: 20,
      help: "Idle capacity.",
    }
    let update = {
      ..legacy,
      schema: Some([registration.schema[0], standby]),
      defaults: Some({ "image": "runner:default", "standby_workers": "0" }),
    }
    try
      c.sync_provider("b".repeat(64), { ..update, controller_id: "other", })
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ =>
        fail("another controller changed the schema while the lease was held")
    }
    assert_eq(
      c.provider_control(admin, provider.id).snapshot.schema.length(),
      1,
    )
    let upgraded = c.sync_provider("b".repeat(64), update)
    assert_eq(upgraded.config_revision, "3")
    assert_eq(upgraded.config.get("image"), Some("runner:saved"))
    assert_eq(upgraded.config.get("standby_workers"), Some("0"))
    let control = c.provider_control(admin, provider.id)
    assert_eq(control.status, "pending")
    assert_eq(control.applied_revision, 2L)
    assert_eq(c.sync_provider("b".repeat(64), update).config_revision, "3")
    c.save_provider_config(admin, provider.id, 3L, {
      "image": "runner:saved",
      "standby_workers": "2",
    })
    let applied = c.sync_provider("b".repeat(64), {
      ..update,
      observed_revision: "4",
      applied_revision: "4",
    })
    assert_eq(applied.config_revision, "4")
    assert_eq(applied.config.get("standby_workers"), Some("2"))
    assert_eq(c.provider_control(admin, provider.id).status, "applied")
    let changed = { ..registration.schema[0], title: "Changed existing field", }
    try
      c.sync_provider("b".repeat(64), {
        ..update,
        schema: Some([changed, standby]),
      })
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("changed an existing schema field")
    }
    try
      c.sync_provider("b".repeat(64), {
        ..update,
        schema: Some(registration.schema),
        defaults: Some(registration.defaults),
      })
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("removed an existing schema field")
    }
    try c.sync_provider("b".repeat(64), { ..update, defaults: None, }) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted schema without defaults")
    }
    assert_eq(
      c.provider_control(admin, provider.id).snapshot.config_revision,
      "4",
    )
    assert_eq(
      c.provider_control(admin, provider.id).snapshot.config.get("image"),
      Some("runner:saved"),
    )
  })
}

///|
async test "prepared VM workers acknowledge drain only after explicit cleanup" {
  @test_support.with_repository_test_data((pool, _) => {
    let c = Coordinator::new(pool)
    let admin = @identity.active_user_by_name(pool, "admin")
    let provider = c.create_provider(
      admin,
      "managed",
      "a".repeat(64),
      ["self-hosted", "macos", "arm64"],
      [],
    )
    ignore(
      c.register_runner("a".repeat(64), {
        ..control_registration(),
        mode: "tart",
      }),
    )
    let worker = c.register_worker("b".repeat(64), {
      version: 1,
      key: "mac",
      token: "c".repeat(64),
    })
    let ready : @protocol.WorkerSyncRequest = {
      version: 1,
      state: "ready",
      applied_revision: "1",
    }
    ignore(c.sync_worker("c".repeat(64), ready))
    c.drain_worker("b".repeat(64), @protocol.parse_decimal(worker.id).unwrap())
    assert_true(c.sync_worker("c".repeat(64), ready).draining)
    assert_eq(
      c.provider_control(admin, provider.id).snapshot.workers[0].state,
      "ready",
    )
    ignore(c.sync_worker("c".repeat(64), { ..ready, state: "starting", }))
    assert_eq(
      c.provider_control(admin, provider.id).snapshot.workers[0].state,
      "starting",
    )
    ignore(c.sync_worker("c".repeat(64), { ..ready, state: "drained", }))
    assert_eq(
      c.provider_control(admin, provider.id).snapshot.workers[0].state,
      "drained",
    )
  })
}

///|
async test "Windows prepared workspaces require explicit drain acknowledgement" {
  @test_support.with_repository_test_data((pool, _) => {
    let c = Coordinator::new(pool)
    let admin = @identity.active_user_by_name(pool, "admin")
    let provider = c.create_provider(
      admin,
      "managed",
      "a".repeat(64),
      ["self-hosted", "windows", "x64"],
      [],
    )
    ignore(c.register_runner("a".repeat(64), control_registration(mode="asg")))
    let worker = c.register_worker("b".repeat(64), {
      version: 1,
      key: "windows",
      token: "c".repeat(64),
    })
    let ready : @protocol.WorkerSyncRequest = {
      version: 1,
      state: "ready",
      applied_revision: "1",
    }
    ignore(c.sync_worker("c".repeat(64), ready))
    c.drain_worker("b".repeat(64), @protocol.parse_decimal(worker.id).unwrap())
    // A ready request can be in flight while the controller requests drain.
    // The worker still owns its prepared workspace until it observes the reply.
    assert_true(c.sync_worker("c".repeat(64), ready).draining)
    assert_eq(
      c.provider_control(admin, provider.id).snapshot.workers[0].state,
      "ready",
    )
    ignore(c.sync_worker("c".repeat(64), { ..ready, state: "starting", }))
    assert_eq(
      c.provider_control(admin, provider.id).snapshot.workers[0].state,
      "starting",
    )
    ignore(c.sync_worker("c".repeat(64), { ..ready, state: "drained", }))
    assert_eq(
      c.provider_control(admin, provider.id).snapshot.workers[0].state,
      "drained",
    )
  })
}
