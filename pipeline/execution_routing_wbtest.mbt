///|
let adaptive_workflow : String =
  #|name: Adaptive
  #|on: workflow_dispatch
  #|jobs:
  #|  build:
  #|    runs-on: ubuntu-24.04
  #|    steps:
  #|      - id: check
  #|        run: docker build .
  #|  after:
  #|    needs: build
  #|    runs-on: ubuntu-24.04
  #|    steps:
  #|      - id: after
  #|        run: echo after

///|
async fn with_execution_fixture(
  f : async (
    Coordinator,
    @database.Database,
    String,
    @domain.CurrentUser,
    @domain.CurrentUser,
    Int64,
    Int64,
  ) -> Unit,
  clock? : () -> Int64,
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let c = Coordinator::new(pool, clock?)
    ignore(
      @test_support.workflow_commit(
        protocol_repo.git_dir(root),
        adaptive_workflow,
      ),
    )
    let labels = ["self-hosted", "linux", "x64", "ubuntu-24.04"]
    let normal = c.create_provider(admin, "normal", "a".repeat(64), labels, [
      protocol_repo,
    ])
    let ci = c.create_provider(admin, "ci", "c".repeat(64), labels, [
      protocol_repo,
    ])
    let registration = control_registration()
    ignore(
      c.register_runner("a".repeat(64), {
        ..registration,
        name: "normal",
        provider_token: "b".repeat(64),
      }),
    )
    let schema = registration.schema.copy()
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
    ignore(
      c.register_runner("c".repeat(64), {
        ..registration,
        name: "ci",
        mode: "asg",
        provider_token: "d".repeat(64),
        schema,
        defaults: { "image": "runner:v1", "execution_mode": "linux-ci" },
      }),
    )
    let sync : @protocol.ProviderSyncRequest = {
      version: 1,
      controller_id: "manager",
      observed_revision: "1",
      applied_revision: "1",
      status: "applied",
      schema: None,
      defaults: None,
    }
    ignore(c.sync_provider("b".repeat(64), sync))
    ignore(c.sync_provider("d".repeat(64), sync))
    let normal_worker = c.register_worker("b".repeat(64), {
      version: 1,
      key: "reusable",
      token: "e".repeat(64),
    })
    let ci_worker = c.register_worker("d".repeat(64), {
      version: 1,
      key: "i-single",
      token: "f".repeat(64),
    })
    let ready : @protocol.WorkerSyncRequest = {
      version: 1,
      state: "ready",
      applied_revision: "1",
    }
    ignore(c.sync_worker("e".repeat(64), ready))
    ignore(c.sync_worker("f".repeat(64), ready))
    c.arm_ci_worker(
      "d".repeat(64),
      "manager",
      @protocol.parse_decimal(ci_worker.id).unwrap(),
      1L,
    )
    c.save_execution_environment(admin, "ubuntu-x64", 0L, {
      label: "ubuntu-24.04",
      architecture: "x64",
      environment_version: "v1",
      routing: "adaptive",
      restricted_provider: "normal",
      linux_ci_provider: "ci",
    })
    f(c, pool, root, actor, admin, normal.id, ci.id)
    ignore(normal_worker)
  })
}

///|
async test "adaptive routing shares claim and demand and retries only after outside cleanup" {
  with_execution_fixture((c, pool, root, actor, admin, normal, ci) => {
    save_execution_policy(pool, actor, protocol_repo, 0L, true)
    let run = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    assert_eq(c.provider_control(admin, normal).snapshot.queued_jobs, 1)
    assert_eq(c.provider_control(admin, ci).snapshot.queued_jobs, 0)
    assert_true(
      c.claim("f".repeat(64), claim_request(secret="1".repeat(64))) is None,
    )
    let first = c
      .claim("e".repeat(64), claim_request(secret="2".repeat(64)))
      .unwrap()
    assert_eq(first.version, @protocol.execution_assignment_version)
    assert_eq(first.execution.unwrap().profile, "restricted")
    let id = @protocol.parse_decimal(first.attempt_id).unwrap()
    ignore(c.start(id, "2".repeat(64), 1))
    pool.with_client(d => {
      ignore(
        d.execute(
          "INSERT INTO pipeline_artifact(repository_id,run_id,attempt_id,name,storage_key,state,created_ms,expires_ms) VALUES(?,?,?,?,?,'ready',1,9999999999999)",
          params=[run.repository_id, run.id, id, "build-output", "a".repeat(64)],
        ),
      )
    })
    let report = {
      ..completion(conclusion="failure"),
      missing_capability: "docker",
    }
    ignore(c.complete(id, "2".repeat(64), report))
    ignore(c.complete(id, "2".repeat(64), report))
    assert_eq(
      pool.with_client(d => {
        (
          d
          .query_one("SELECT state FROM pipeline_artifact WHERE attempt_id=?", params=[
            id,
          ])
          .get_name("state") : String)
      }),
      "deleted",
    )
    assert_eq(get_run(pool, actor, protocol_repo, run.number).state, Running)
    assert_eq(
      list_jobs(pool, actor, protocol_repo, run.number)[1].state,
      Waiting,
    )
    assert_eq(c.provider_control(admin, ci).snapshot.queued_jobs, 0)
    assert_true(
      c.claim("f".repeat(64), claim_request(secret="3".repeat(64))) is None,
    )
    c.execution_cleanup("e".repeat(64), id)
    c.execution_cleanup("e".repeat(64), id)
    assert_eq(c.provider_control(admin, ci).snapshot.queued_jobs, 1)
    assert_eq(c.provider_control(admin, normal).snapshot.queued_jobs, 0)
    let second = c
      .claim("f".repeat(64), claim_request(id="2", secret="4".repeat(64)))
      .unwrap()
    assert_eq(second.job_id, first.job_id)
    assert_eq(second.execution.unwrap().profile, "linux-ci")
    let sid = @protocol.parse_decimal(second.attempt_id).unwrap()
    ignore(c.start(sid, "4".repeat(64), 1))
    ignore(c.complete(sid, "4".repeat(64), completion()))
    assert_eq(
      list_jobs(pool, actor, protocol_repo, run.number)[1].state,
      Queued,
    )
    let history = execution_history(pool, actor, protocol_repo, run.number).stringify()
    assert_true(history.contains("capability_fallback"))
    assert_true(history.contains("missing_capability"))
  })
}

///|
async test "capability learning survives unchanged workflow commits without enabling automatic retry" {
  with_execution_fixture((c, pool, root, actor, admin, normal, ci) => {
    let run = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    let first = c
      .claim("e".repeat(64), claim_request(secret="2".repeat(64)))
      .unwrap()
    let id = @protocol.parse_decimal(first.attempt_id).unwrap()
    ignore(c.start(id, "2".repeat(64), 1))
    ignore(
      c.complete(id, "2".repeat(64), {
        ..completion(conclusion="failure"),
        missing_capability: "docker",
      }),
    )
    assert_eq(
      get_run(pool, actor, protocol_repo, run.number).conclusion,
      Some(Failure),
    )
    ignore(
      @test_support.workflow_commit(
        protocol_repo.git_dir(root),
        adaptive_workflow,
      ),
    )
    let next = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    assert_eq(c.provider_control(admin, normal).snapshot.queued_jobs, 0)
    assert_eq(c.provider_control(admin, ci).snapshot.queued_jobs, 1)
    let second = c
      .claim("f".repeat(64), claim_request(secret="3".repeat(64)))
      .unwrap()
    assert_eq(second.run_id, next.id.to_string())
    assert_eq(second.execution.unwrap().profile, "linux-ci")
    let environments = c.execution_environments(admin)
    c.save_execution_environment(admin, "ubuntu-x64", 1L, {
      ..environments[0].config,
      environment_version: "v2",
    })
    let newer = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    assert_eq(c.provider_control(admin, normal).snapshot.queued_jobs, 1)
    assert_true(newer.id > next.id)
  })
}

///|
async test "ordinary failure never learns capabilities and fallback cannot bypass grants or cancellation" {
  with_execution_fixture((c, pool, root, actor, admin, normal, ci) => {
    save_execution_policy(pool, actor, protocol_repo, 0L, true)
    let run = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    let first = c
      .claim("e".repeat(64), claim_request(secret="2".repeat(64)))
      .unwrap()
    let id = @protocol.parse_decimal(first.attempt_id).unwrap()
    ignore(c.start(id, "2".repeat(64), 1))
    ignore(c.complete(id, "2".repeat(64), completion(conclusion="failure")))
    assert_eq(
      get_run(pool, actor, protocol_repo, run.number).conclusion,
      Some(Failure),
    )
    assert_eq(
      pool.with_client(d => {
        (
          d
          .query_one("SELECT COUNT(*) n FROM pipeline_execution_learning")
          .get_name("n") : Int64)
      }),
      0L,
    )
    let next = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    c.set_provider_paused(admin, ci, true)
    ignore(
      c.sync_worker("e".repeat(64), {
        version: 1,
        state: "ready",
        applied_revision: "1",
      }),
    )
    let retry = c
      .claim("e".repeat(64), claim_request(id="2", secret="3".repeat(64)))
      .unwrap()
    let rid = @protocol.parse_decimal(retry.attempt_id).unwrap()
    ignore(c.start(rid, "3".repeat(64), 1))
    ignore(
      c.complete(rid, "3".repeat(64), {
        ..completion(conclusion="failure"),
        missing_capability: "docker",
      }),
    )
    assert_eq(
      get_run(pool, actor, protocol_repo, next.number).conclusion,
      Some(Failure),
    )
    assert_eq(c.provider_control(admin, normal).snapshot.queued_jobs, 0)
  })
}

///|
async test "capability fallback keeps original deadline and cancellation wins over cleanup acknowledgement" {
  let clock = Ref(1700000000000L)
  with_execution_fixture(
    (c, pool, root, actor, admin, _, ci) => {
      save_execution_policy(pool, actor, protocol_repo, 0L, true)
      let run = create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      )
      let a = c
        .claim("e".repeat(64), claim_request(secret="1".repeat(64)))
        .unwrap()
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      let original = c.start(id, "1".repeat(64), 1)
      ignore(
        c.complete(id, "1".repeat(64), {
          ..completion(conclusion="failure"),
          missing_capability: "docker",
        }),
      )
      clock.val += 1000L
      c.execution_cleanup("e".repeat(64), id)
      let b = c
        .claim("f".repeat(64), claim_request(secret="2".repeat(64)))
        .unwrap()
      let bid = @protocol.parse_decimal(b.attempt_id).unwrap()
      let retried = c.start(bid, "2".repeat(64), 1)
      assert_eq(retried.deadline_ms, original.deadline_ms)
      c.cancel_run(actor, protocol_repo, run.number)
      assert_true(c.heartbeat(bid, "2".repeat(64), 1).cancel_requested)
      ignore(c.complete(bid, "2".repeat(64), completion(conclusion="failure")))
      assert_eq(
        get_run(pool, actor, protocol_repo, run.number).conclusion,
        Some(Cancelled),
      )
      assert_eq(c.provider_control(admin, ci).snapshot.queued_jobs, 0)
    },
    clock=() => clock.val,
  )
}

///|
async test "missing cleanup acknowledgement ends the logical job without starting another attempt" {
  let clock = Ref(1700000000000L)
  with_execution_fixture(
    (c, pool, root, actor, admin, _, ci) => {
      save_execution_policy(pool, actor, protocol_repo, 0L, true)
      let run = create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      )
      let a = c
        .claim("e".repeat(64), claim_request(secret="1".repeat(64)))
        .unwrap()
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      ignore(c.start(id, "1".repeat(64), 1))
      ignore(
        c.complete(id, "1".repeat(64), {
          ..completion(conclusion="failure"),
          missing_capability: "docker",
        }),
      )
      clock.val += 120001L
      ignore(c.expire_attempts())
      assert_eq(
        get_run(pool, actor, protocol_repo, run.number).conclusion,
        Some(Failure),
      )
      assert_eq(c.provider_control(admin, ci).snapshot.queued_jobs, 0)
      assert_eq(
        pool.with_client(d => {
          (
            d
            .query_one("SELECT COUNT(*) n FROM pipeline_job_attempt")
            .get_name("n") : Int64)
        }),
        1L,
      )
    },
    clock=() => clock.val,
  )
}

///|
async test "capability observations do not cross branches or survive changed workflow content" {
  with_execution_fixture((c, pool, root, actor, admin, normal, ci) => {
    let run = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    let a = c
      .claim("e".repeat(64), claim_request(secret="1".repeat(64)))
      .unwrap()
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.start(id, "1".repeat(64), 1))
    ignore(
      c.complete(id, "1".repeat(64), {
        ..completion(conclusion="failure"),
        missing_capability: "docker",
      }),
    )
    let sha = @gitops.merge_git(protocol_repo.git_dir(root), [
        "rev-parse", "refs/heads/pipeline",
      ])
      .trim()
      .to_owned()
    ignore(
      @gitops.merge_git(protocol_repo.git_dir(root), [
        "update-ref", "refs/heads/feature", sha,
      ]),
    )
    let branch = create_run(
      pool, root, actor, protocol_repo, "feature", ".github/workflows/build.yml",
    )
    assert_eq(c.provider_control(admin, normal).snapshot.queued_jobs, 1)
    assert_eq(c.provider_control(admin, ci).snapshot.queued_jobs, 0)
    let changed = adaptive_workflow + "\n# change contract\n"
    ignore(@test_support.workflow_commit(protocol_repo.git_dir(root), changed))
    let newer = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    assert_eq(c.provider_control(admin, normal).snapshot.queued_jobs, 2)
    assert_true(branch.id > run.id && newer.id > branch.id)
  })
}

///|
async test "capability fallback respects target repository grants and cleanup rejects attempt credentials" {
  with_execution_fixture((c, pool, root, actor, admin, _, ci) => {
    save_execution_policy(pool, actor, protocol_repo, 0L, true)
    let run = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    let a = c
      .claim("e".repeat(64), claim_request(secret="1".repeat(64)))
      .unwrap()
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.start(id, "1".repeat(64), 1))
    c.set_provider_scope(admin, ci, SelectedRepositories, [])
    ignore(
      c.complete(id, "1".repeat(64), {
        ..completion(conclusion="failure"),
        missing_capability: "docker",
      }),
    )
    assert_eq(
      get_run(pool, actor, protocol_repo, run.number).conclusion,
      Some(Failure),
    )
    try c.execution_cleanup("1".repeat(64), id) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("attempt credential acknowledged outside cleanup")
    }
    assert_eq(
      pool.with_client(d => {
        (
          d
          .query_one("SELECT COUNT(*) n FROM pipeline_job_attempt")
          .get_name("n") : Int64)
      }),
      1L,
    )
  })
}

///|
async test "environment routing and retry policy are captured and subsequent edits affect only new runs" {
  with_execution_fixture((c, pool, root, actor, admin, _, ci) => {
    let run = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    save_execution_policy(pool, actor, protocol_repo, 0L, true)
    let config = c.execution_environments(admin)[0].config
    c.save_execution_environment(admin, "ubuntu-x64", 1L, {
      ..config,
      routing: "linux-ci",
    })
    let a = c
      .claim("e".repeat(64), claim_request(secret="1".repeat(64)))
      .unwrap()
    assert_eq(a.execution.unwrap().profile, "restricted")
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.start(id, "1".repeat(64), 1))
    ignore(
      c.complete(id, "1".repeat(64), {
        ..completion(conclusion="failure"),
        missing_capability: "docker",
      }),
    )
    assert_eq(
      get_run(pool, actor, protocol_repo, run.number).conclusion,
      Some(Failure),
    )
    let next = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    assert_eq(c.provider_control(admin, ci).snapshot.queued_jobs, 1)
    assert_true(next.id > run.id)
  })
}
