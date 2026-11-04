///|
let protocol_repo : @domain.RepoId = { owner: "alice", name: "demo", }

///|
let provider_secret : String = "a".repeat(64)

///|
let attempt_secret : String = "b".repeat(64)

///|
fn claim_request(
  id~ : String = "1",
  secret~ : String = attempt_secret,
) -> @protocol.ClaimRequest {
  {
    runner_os: None,
    version: 1,
    request_id: id.repeat(32),
    attempt_token: secret,
  }
}

///|
fn log_request(sequence : Int64, text : String) -> @protocol.LogRequest {
  {
    version: 1,
    sequence: sequence.to_string(),
    step_id: "check",
    stream: "stdout",
    text,
  }
}

///|
fn completion(
  conclusion~ : String = "success",
  last~ : Int64 = 0L,
) -> @protocol.CompleteRequest {
  { version: 1, conclusion, last_log_sequence: last.to_string(), }
}

///|
let dag_workflow : String =
  #|name: DAG
  #|on: workflow_dispatch
  #|jobs:
  #|  build:
  #|    runs-on: [self-hosted, linux]
  #|    steps:
  #|      - id: build
  #|        run: echo build
  #|  test:
  #|    needs: build
  #|    runs-on: self-hosted
  #|    steps:
  #|      - id: test
  #|        run: echo test
  #|  deploy:
  #|    needs: [test]
  #|    runs-on: self-hosted
  #|    steps:
  #|      - id: deploy
  #|        run: echo deploy

///|
async fn with_dag_fixture(
  f : async (Coordinator, @database.Database, @domain.RepoId, Run, String) -> Unit,
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    ignore(@test_support.workflow_commit(repo.git_dir(root), dag_workflow))
    let coordinator = Coordinator::new(pool)
    let provider_token = @identity.random_hex(32)
    ignore(
      coordinator.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "dag-provider",
        provider_token,
        ["self-hosted", "linux"],
        [repo],
      ),
    )
    let run = create_run(
      pool,
      root,
      @identity.active_user_by_name(pool, "alice"),
      repo,
      "pipeline",
      ".github/workflows/build.yml",
    )
    f(coordinator, pool, repo, run, provider_token)
  })
}

///|
fn claim_dag_attempt(
  coordinator : Coordinator,
  provider_token : String,
) -> (@protocol.Assignment, String) raise {
  let attempt_token = @identity.random_hex(32)
  let assignment = coordinator
    .claim(provider_token, {
      version: 1,
      runner_os: None,
      request_id: @identity.random_hex(16),
      attempt_token,
    })
    .unwrap()
  (assignment, attempt_token)
}

///|
async test "claim advances a multi-job DAG after each successful attempt" {
  with_dag_fixture((coordinator, pool, repo, run, provider_token) => {
    let (build, build_token) = claim_dag_attempt(coordinator, provider_token)
    assert_eq(build.job.id, "build")
    ignore(
      coordinator.start(
        @protocol.parse_decimal(build.attempt_id).unwrap(),
        build_token,
        1,
      ),
    )
    ignore(
      coordinator.complete(
        @protocol.parse_decimal(build.attempt_id).unwrap(),
        build_token,
        completion(),
      ),
    )
    let (test_assignment, test_token) = claim_dag_attempt(
      coordinator, provider_token,
    )
    assert_eq(test_assignment.job.id, "test")
    ignore(
      coordinator.start(
        @protocol.parse_decimal(test_assignment.attempt_id).unwrap(),
        test_token,
        1,
      ),
    )
    ignore(
      coordinator.complete(
        @protocol.parse_decimal(test_assignment.attempt_id).unwrap(),
        test_token,
        completion(),
      ),
    )
    let (deploy_assignment, deploy_token) = claim_dag_attempt(
      coordinator, provider_token,
    )
    assert_eq(deploy_assignment.job.id, "deploy")
    ignore(
      coordinator.start(
        @protocol.parse_decimal(deploy_assignment.attempt_id).unwrap(),
        deploy_token,
        1,
      ),
    )
    ignore(
      coordinator.complete(
        @protocol.parse_decimal(deploy_assignment.attempt_id).unwrap(),
        deploy_token,
        completion(),
      ),
    )
    assert_eq(
      get_run(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        repo,
        run.number,
      ).state,
      Completed,
    )
    let jobs = list_jobs(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      repo,
      run.number,
    )
    assert_true(
      jobs.all(job => job.state is Completed && job.conclusion is Some(Success)),
    )
  })
}

///|
async test "failed DAG dependencies skip all downstream jobs" {
  with_dag_fixture((coordinator, pool, repo, run, provider_token) => {
    let build_token = @identity.random_hex(32)
    let build = coordinator
      .claim(provider_token, {
        version: 1,
        runner_os: None,
        request_id: @identity.random_hex(16),
        attempt_token: build_token,
      })
      .unwrap()
    ignore(
      coordinator.start(
        @protocol.parse_decimal(build.attempt_id).unwrap(),
        build_token,
        1,
      ),
    )
    ignore(
      coordinator.complete(
        @protocol.parse_decimal(build.attempt_id).unwrap(),
        build_token,
        completion(conclusion="failure"),
      ),
    )
    assert_true(
      coordinator.claim(provider_token, {
        version: 1,
        runner_os: None,
        request_id: @identity.random_hex(16),
        attempt_token: @identity.random_hex(32),
      })
      is None,
    )
    let jobs = list_jobs(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      repo,
      run.number,
    )
    assert_true(
      jobs.iter().find_first(job => job.job_key == "build").unwrap().conclusion
      is Some(Failure),
    )
    for key in ["test", "deploy"] {
      let job = jobs.iter().find_first(job => job.job_key == key).unwrap()
      assert_true(job.state is Completed)
      assert_true(job.conclusion is Some(Skipped))
    }
    assert_eq(
      get_run(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        repo,
        run.number,
      ).conclusion,
      Some(Failure),
    )
  })
}

///|
async fn with_protocol_fixture(
  f : async (Coordinator, @database.Database, String, Run, Provider, Ref[Int64]) -> Unit,
  workflow~ : String = @test_support.single_job_workflow,
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let clock = Ref(1700000000000L)
    let coordinator = Coordinator::new(pool, clock=() => clock.val)
    let admin = @identity.active_user_by_name(pool, "admin")
    let provider = coordinator.create_provider(
      admin,
      "default",
      provider_secret,
      ["self-hosted", "linux"],
      [protocol_repo],
    )
    ignore(@test_support.workflow_commit(protocol_repo.git_dir(root), workflow))
    let run = create_run(
      pool,
      root,
      @identity.active_user_by_name(pool, "alice"),
      protocol_repo,
      "pipeline",
      ".github/workflows/build.yml",
    )
    f(coordinator, pool, root, run, provider, clock)
  })
}

///|
test "provider protocol helpers reject unsupported versions and invalid tokens" {
  try check_version(2) catch {
    @domain.BadRequest(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted version")
  }
  for token in ["", "b".repeat(63), "B".repeat(64), "x".repeat(64)] {
    try check_token(token) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted token")
    }
  }
}

///|
async test "provider ensure is idempotent and refuses credential replacement" {
  with_protocol_fixture((coordinator, pool, _, _, provider, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let ensured = coordinator.ensure_provider(
      admin,
      provider.name,
      provider_secret,
      ["self-hosted", "linux"],
      [protocol_repo],
    )
    assert_eq(ensured.id, provider.id)
    assert_eq(
      pool.with_client(client => {
        client.query_all("SELECT id FROM pipeline_provider").length()
      }),
      1,
    )
    try
      ignore(
        coordinator.ensure_provider(
          admin,
          provider.name,
          "c".repeat(64),
          ["self-hosted", "linux"],
          [protocol_repo],
        ),
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("provider ensure replaced an existing credential")
    }
  })
}

///|
async test "bound executions reject other instances and cannot complete before steps succeed" {
  with_protocol_fixture((coordinator, pool, _, run, _, _) => {
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    let nonce = "e".repeat(32)
    assert_eq(
      coordinator.start(id, attempt_secret, 1, execution_id=nonce).execution_id,
      nonce,
    )
    assert_eq(
      coordinator.start(id, attempt_secret, 1, execution_id=nonce).execution_id,
      nonce,
    )
    for execution_id in ["", "f".repeat(32)] {
      try
        ignore(coordinator.start(id, attempt_secret, 1, execution_id~))
      catch {
        Conflict(_) => ()
        err => raise err
      } noraise {
        _ => fail("another execution attached to a live attempt")
      }
    }
    try ignore(coordinator.complete(id, attempt_secret, completion())) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("completed before executing any step")
    }
    let running : @protocol.StepRequest = {
      version: 1,
      step_id: "check",
      state: "running",
      exit_code: 0,
    }
    ignore(coordinator.update_step(id, attempt_secret, running))
    ignore(coordinator.update_step(id, attempt_secret, running))
    try
      ignore(
        coordinator.update_step(id, attempt_secret, {
          ..running,
          state: "success",
          exit_code: 1,
        }),
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("success with failed exit code")
    }
    let done = { ..running, state: "success", }
    ignore(coordinator.update_step(id, attempt_secret, done))
    ignore(coordinator.update_step(id, attempt_secret, done))
    ignore(coordinator.complete(id, attempt_secret, completion()))
    let state = coordinator.read_steps(
      @identity.active_user_by_name(pool, "alice"),
      protocol_repo,
      run.number,
      id,
    )
    assert_eq(state.length(), 1)
    assert_eq(state[0].state, "success")
  })
}

///|
async test "claim allocation is idempotent across coordinator restarts and does not leak credentials" {
  with_protocol_fixture((coordinator, pool, _, run, _, clock) => {
    let request = claim_request()
    let first = coordinator.claim(provider_secret, request).unwrap()
    let restarted = Coordinator::new(pool, clock=() => clock.val)
    let replay = restarted.claim(provider_secret, request).unwrap()
    assert_eq(ToJson::to_json(first), ToJson::to_json(replay))
    assert_eq(@protocol.parse_decimal(first.run_id).unwrap(), run.id)
    assert_eq(first.commit_sha, run.commit_sha)
    assert_eq(first.repository, "alice/demo")
    assert_true(!ToJson::to_json(first).stringify().contains(attempt_secret))
    assert_true(
      restarted.claim(
        provider_secret,
        claim_request(id="2", secret="d".repeat(64)),
      )
      is None,
    )
    try
      ignore(
        restarted.claim(provider_secret, claim_request(secret="c".repeat(64))),
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("reused claim id with different token")
    }
    try
      ignore(
        restarted.start(
          @protocol.parse_decimal(first.attempt_id).unwrap(),
          provider_secret,
          1,
        ),
      )
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("provider token impersonated attempt")
    }
    pool.with_client(client => {
      assert_eq(
        client.query_all("SELECT id FROM pipeline_job_attempt").length(),
        1,
      )
      let row = client.query_one("SELECT token_hash FROM pipeline_job_attempt")
      assert_eq(
        (row.get_name("token_hash") : String),
        @identity.hash_token(attempt_secret),
      )
      assert_eq(
        (
          client
          .query_one("SELECT token_hash FROM pipeline_provider")
          .get_name("token_hash") : String),
        @identity.hash_token(provider_secret),
      )
    })
  })
}

///|
async test "only one provider claims a job and provider scope and labels are enforced" {
  with_protocol_fixture((coordinator, pool, _, _, _, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let other = "c".repeat(64)
    ignore(
      coordinator.create_provider(
        admin,
        "other",
        other,
        ["self-hosted", "linux"],
        [],
      ),
    )
    assert_true(
      coordinator.claim(other, claim_request(secret="d".repeat(64))) is None,
    )
    let first = coordinator.claim(provider_secret, claim_request()).unwrap()
    let other_provider : Int64 = coordinator.pool.with_client(client => {
      client
      .query_one("SELECT id FROM pipeline_provider WHERE name = 'other'")
      .get_name("id")
    })
    coordinator.set_provider_repository(
      admin, other_provider, protocol_repo, true,
    )
    assert_true(
      coordinator.claim(other, claim_request(secret="d".repeat(64))) is None,
    )
    assert_eq(
      @protocol.parse_decimal(first.job_id).unwrap(),
      coordinator.pool.with_client(client => {
        client
        .query_one("SELECT job_id FROM pipeline_job_attempt")
        .get_name("job_id")
      }),
    )
    let alice = @identity.active_user_by_name(pool, "alice")
    try
      ignore(
        coordinator.create_provider(
          alice,
          "forged",
          "e".repeat(64),
          ["self-hosted", "linux"],
          [protocol_repo],
        ),
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("non-admin registered provider")
    }
  })
}

///|
async test "logs are ordered bounded idempotent and mask attempt credentials across chunks" {
  with_protocol_fixture((coordinator, pool, _, run, _, _) => {
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    try
      ignore(
        coordinator.append_log(id, attempt_secret, log_request(1L, "early")),
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("logged before starting")
    }
    ignore(coordinator.start(id, attempt_secret, 1))
    let first = log_request(1L, "token=" + attempt_secret[:32].to_owned())
    ignore(coordinator.append_log(id, attempt_secret, first))
    ignore(coordinator.append_log(id, attempt_secret, first))
    let reader = @identity.active_user_by_name(pool, "alice")
    assert_eq(
      coordinator
      .read_logs(reader, protocol_repo, run.number, id)
      .map(chunk => chunk.text)
      .join(""),
      "token=",
    )
    try
      ignore(
        coordinator.append_log(id, attempt_secret, log_request(1L, "different")),
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("changed duplicate log")
    }
    try
      ignore(coordinator.append_log(id, attempt_secret, log_request(3L, "gap")))
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted gap")
    }
    ignore(
      coordinator.append_log(
        id,
        attempt_secret,
        log_request(2L, attempt_secret[32:].to_owned() + "\n"),
      ),
    )
    let chunks = coordinator.read_logs(reader, protocol_repo, run.number, id)
    assert_eq(chunks.map(chunk => chunk.text).join(""), "token=***\n")
    assert_true(
      coordinator
      .read_logs(
        reader,
        protocol_repo,
        run.number,
        id,
        after=@protocol.parse_decimal(chunks.last().unwrap().id).unwrap(),
      )
      .is_empty(),
    )
    try
      ignore(coordinator.complete(id, attempt_secret, completion(last=3L)))
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("completed with unacknowledged logs")
    }
    let done = coordinator.complete(id, attempt_secret, completion(last=2L))
    assert_eq(done.conclusion, "success")
    assert_eq(
      ToJson::to_json(
        coordinator.complete(id, attempt_secret, completion(last=2L)),
      ),
      ToJson::to_json(done),
    )
    try
      ignore(
        coordinator.complete(
          id,
          attempt_secret,
          completion(conclusion="failure", last=2L),
        ),
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("overwrote completion")
    }
    assert_eq(
      get_run(pool, reader, protocol_repo, run.number).conclusion,
      Some(Success),
    )
    try
      ignore(
        coordinator.read_logs(
          @identity.active_user_by_name(pool, "bob"),
          protocol_repo,
          run.number,
          id,
        ),
      )
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("read private logs")
    }
  })
}

///|
async test "expired attempts become lost and never revive or overwrite a fresh attempt" {
  with_protocol_fixture((coordinator, pool, root, run, _, clock) => {
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    let lease = clock.val + @protocol.lease_ms
    clock.val += 30000L
    assert_eq(
      coordinator.heartbeat(id, attempt_secret, 1).lease_until_ms,
      lease.to_string(),
    )
    clock.val = lease
    try ignore(coordinator.heartbeat(id, attempt_secret, 1)) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("renewed expired lease")
    }
    let actor = @identity.active_user_by_name(pool, "alice")
    assert_eq(
      get_run(pool, actor, protocol_repo, run.number).conclusion,
      Some(Lost),
    )
    assert_true(
      coordinator.claim(
        provider_secret,
        claim_request(id="2", secret="d".repeat(64)),
      )
      is None,
    )
    try ignore(coordinator.claim(provider_secret, claim_request())) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("revived lost claim")
    }
    let next = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    let fresh = coordinator
      .claim(provider_secret, claim_request(id="2", secret="d".repeat(64)))
      .unwrap()
    assert_eq(@protocol.parse_decimal(fresh.run_id).unwrap(), next.id)
    try
      ignore(
        coordinator.complete(
          id,
          attempt_secret,
          completion(conclusion="failure"),
        ),
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("late result changed lost attempt")
    }
    try
      ignore(
        coordinator.start(
          @protocol.parse_decimal(fresh.attempt_id).unwrap(),
          attempt_secret,
          1,
        ),
      )
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("old token controlled new attempt")
    }
    assert_eq(get_run(pool, actor, protocol_repo, next.number).state, Running)
  })
}

///|
async test "job deadline is fixed at first start and heartbeats cannot extend it" {
  with_protocol_fixture((coordinator, pool, _, run, _, clock) => {
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    let start = coordinator.start(id, attempt_secret, 1)
    clock.val += 30000L
    let again = coordinator.start(id, attempt_secret, 1)
    assert_eq(
      @protocol.parse_decimal(again.lease_until_ms).unwrap(),
      @protocol.parse_decimal(start.lease_until_ms).unwrap(),
    )
    assert_eq(
      coordinator.heartbeat(id, attempt_secret, 1).lease_until_ms,
      start.lease_until_ms,
    )
    clock.val = @protocol.parse_decimal(start.lease_until_ms).unwrap()
    assert_eq(coordinator.expire_attempts(), 1)
    assert_eq(
      get_run(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        protocol_repo,
        run.number,
      ).conclusion,
      Some(TimedOut),
    )
  })
}

///|
async test "cancellation is durable wins completion races and cannot renew forever" {
  with_protocol_fixture((coordinator, pool, _, run, _, clock) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    ignore(coordinator.start(id, attempt_secret, 1))
    coordinator.cancel_run(actor, protocol_repo, run.number)
    let first = coordinator.heartbeat(id, attempt_secret, 1)
    assert_true(first.cancel_requested)
    assert_eq(
      @protocol.parse_decimal(first.lease_until_ms).unwrap(),
      clock.val + @protocol.cancel_grace_ms,
    )
    clock.val += 5000L
    coordinator.cancel_run(actor, protocol_repo, run.number)
    assert_eq(
      coordinator.heartbeat(id, attempt_secret, 1).lease_until_ms,
      first.lease_until_ms,
    )
    let result = coordinator.complete(id, attempt_secret, completion())
    assert_eq(result.conclusion, "cancelled")
    assert_eq(
      (
        pool.with_client(client => {
          client
          .query_one("SELECT reported_conclusion FROM pipeline_job_attempt")
          .get_name("reported_conclusion")
        }) : String),
      "success",
    )
    assert_eq(
      get_run(pool, actor, protocol_repo, run.number).conclusion,
      Some(Cancelled),
    )
  })
}

///|
async test "queued cancellation creates no attempt and cancellation before start cannot execute" {
  with_protocol_fixture((coordinator, pool, root, run, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    coordinator.cancel_run(actor, protocol_repo, run.number)
    assert_true(coordinator.claim(provider_secret, claim_request()) is None)
    assert_eq(
      get_run(pool, actor, protocol_repo, run.number).conclusion,
      Some(Cancelled),
    )
    let next = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    coordinator.cancel_run(actor, protocol_repo, next.number)
    let start = coordinator.start(id, attempt_secret, 1)
    assert_true(start.cancel_requested)
    assert_eq(start.state, "leased")
    ignore(
      coordinator.complete(
        id,
        attempt_secret,
        completion(conclusion="cancelled"),
      ),
    )
    assert_eq(
      get_run(pool, actor, protocol_repo, next.number).conclusion,
      Some(Cancelled),
    )
  })
}

///|
async test "provider pause preserves active work but revocation requests cancellation" {
  with_protocol_fixture((coordinator, pool, _, _, provider, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    coordinator.set_provider_paused(admin, provider.id, true)
    assert_true(coordinator.claim(provider_secret, claim_request()) is None)
    coordinator.set_provider_paused(admin, provider.id, false)
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    ignore(coordinator.start(id, attempt_secret, 1))
    coordinator.set_provider_paused(admin, provider.id, true)
    assert_true(!coordinator.heartbeat(id, attempt_secret, 1).cancel_requested)
    coordinator.revoke_provider(admin, provider.id)
    assert_true(coordinator.heartbeat(id, attempt_secret, 1).cancel_requested)
    try ignore(coordinator.claim(provider_secret, claim_request())) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("revoked provider authenticated")
    }
    assert_eq(
      coordinator.complete(
        id,
        attempt_secret,
        completion(conclusion="cancelled"),
      ).conclusion,
      "cancelled",
    )
  })
}

///|
async test "revoked repository grant and revoked actor both stop active attempts" {
  for revoke_actor in [false, true] {
    with_protocol_fixture((coordinator, pool, _, run, provider, clock) => {
      let id = @protocol.parse_decimal(
        coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
      ).unwrap()
      ignore(coordinator.start(id, attempt_secret, 1))
      if revoke_actor {
        pool.with_client(client => {
          ignore(
            client.execute(
              "UPDATE team_member SET role = 'member' WHERE team_id = 1 AND user_id = 1",
            ),
          )
        })
      } else {
        coordinator.set_provider_repository(
          @identity.active_user_by_name(pool, "admin"),
          provider.id,
          protocol_repo,
          false,
        )
      }
      assert_true(coordinator.heartbeat(id, attempt_secret, 1).cancel_requested)
      clock.val += @protocol.cancel_grace_ms
      assert_eq(coordinator.expire_attempts(), 1)
      assert_eq(
        get_run(
          pool,
          @identity.active_user_by_name(pool, "admin"),
          protocol_repo,
          run.number,
        ).conclusion,
        Some(Lost),
      )
    })
  }
}

///|
async test "log quotas and request versions reject updates without mutating state" {
  with_protocol_fixture((coordinator, _, _, _, _, _) => {
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    try ignore(coordinator.start(id, attempt_secret, 2)) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted unsupported version")
    }
    try ignore(coordinator.complete(id, attempt_secret, completion())) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("success before execution")
    }
    ignore(coordinator.start(id, attempt_secret, 1))
    try
      ignore(
        coordinator.append_log(id, attempt_secret, {
          ..log_request(1L, "text"),
          step_id: "missing",
        }),
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted a missing step")
    }
    try
      ignore(
        coordinator.append_log(
          id,
          attempt_secret,
          log_request(@protocol.max_log_chunks + 1L, "text"),
        ),
      )
    catch {
      LogLimit => ()
      err => raise err
    } noraise {
      _ => fail("accepted too many chunks")
    }
    try
      ignore(
        coordinator.append_log(
          id,
          attempt_secret,
          log_request(1L, "x".repeat(8193)),
        ),
      )
    catch {
      LogLimit => ()
      err => raise err
    } noraise {
      _ => fail("accepted oversized chunk")
    }
    for n = 1; n <= 128; n = n + 1 {
      ignore(
        coordinator.append_log(
          id,
          attempt_secret,
          log_request(n.to_int64(), "x".repeat(8192)),
        ),
      )
    }
    try
      ignore(coordinator.append_log(id, attempt_secret, log_request(129L, "x")))
    catch {
      LogLimit => ()
      err => raise err
    } noraise {
      _ => fail("exceeded total log budget")
    }
    assert_eq(coordinator.heartbeat(id, attempt_secret, 1).log_sequence, "128")
  })
}

///|
async test "claim logs and cancellation survive closing and reopening the durable database" {
  with_protocol_fixture((coordinator, pool, root, run, _, clock) => {
    let assignment = coordinator
      .claim(provider_secret, claim_request())
      .unwrap()
    ignore(
      coordinator.start(
        @protocol.parse_decimal(assignment.attempt_id).unwrap(),
        attempt_secret,
        1,
      ),
    )
    ignore(
      coordinator.append_log(
        @protocol.parse_decimal(assignment.attempt_id).unwrap(),
        attempt_secret,
        log_request(1L, "one\n"),
      ),
    )
    let path = "\{root}/protocol.db"
    pool.with_client(client => {
      ignore(client.execute("VACUUM INTO ?", params=[path]))
    })
    @async.with_task_group(group => {
      let disk = @database.new_db_pool({ path, }, group)
      let mut open = true
      defer (if open { disk.close() })
      let first = Coordinator::new(disk, clock=() => clock.val)
      ignore(
        first.append_log(
          @protocol.parse_decimal(assignment.attempt_id).unwrap(),
          attempt_secret,
          log_request(2L, "two\n"),
        ),
      )
      disk.close()
      open = false
      let reopened = @database.new_db_pool({ path, }, group)
      defer reopened.close()
      @database.initialize_db(reopened)
      let restored = Coordinator::new(reopened, clock=() => clock.val)
      let retry = restored.claim(provider_secret, claim_request()).unwrap()
      assert_eq(
        @protocol.parse_decimal(retry.attempt_id).unwrap(),
        @protocol.parse_decimal(assignment.attempt_id).unwrap(),
      )
      assert_eq(retry.state, "running")
      ignore(
        restored.append_log(
          @protocol.parse_decimal(retry.attempt_id).unwrap(),
          attempt_secret,
          log_request(2L, "two\n"),
        ),
      )
      let actor = @identity.active_user_by_name(reopened, "alice")
      assert_eq(
        restored
        .read_logs(
          actor,
          protocol_repo,
          run.number,
          @protocol.parse_decimal(retry.attempt_id).unwrap(),
        )
        .map(chunk => chunk.text)
        .join(""),
        "one\ntwo\n",
      )
      restored.cancel_run(actor, protocol_repo, run.number)
      let third = Coordinator::new(reopened, clock=() => clock.val)
      assert_true(
        third.heartbeat(
          @protocol.parse_decimal(retry.attempt_id).unwrap(),
          attempt_secret,
          1,
        ).cancel_requested,
      )
      assert_eq(
        third.complete(
          @protocol.parse_decimal(retry.attempt_id).unwrap(),
          attempt_secret,
          completion(conclusion="cancelled", last=2L),
        ).conclusion,
        "cancelled",
      )
    })
  })
}

///|
async test "two consumers on separate SQLite connections cannot allocate the same job" {
  with_protocol_fixture((coordinator, pool, root, _, _, clock) => {
    let other_token = "c".repeat(64)
    ignore(
      coordinator.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "second",
        other_token,
        ["self-hosted", "linux"],
        [protocol_repo],
      ),
    )
    let path = "\{root}/claims.db"
    pool.with_client(client => {
      ignore(client.execute("VACUUM INTO ?", params=[path]))
    })
    @async.with_task_group(group => {
      let one = @database.new_db_pool({ path, }, group)
      defer one.close()
      let two = @database.new_db_pool({ path, }, group)
      defer two.close()
      let one = Coordinator::new(one, clock=() => clock.val)
      let two = Coordinator::new(two, clock=() => clock.val)
      let first = group.spawn(() => {
        @async.pause()
        one.claim(provider_secret, claim_request())
      })
      let second = group.spawn(() => {
        @async.pause()
        two.claim(other_token, claim_request(secret="d".repeat(64)))
      })
      let first = first.wait()
      let second = second.wait()
      assert_true(
        (first is Some(_) && second is None) ||
        (first is None && second is Some(_)),
      )
      assert_eq(
        one.pool.with_client(client => {
          client.query_all("SELECT id FROM pipeline_job_attempt").length()
        }),
        1,
      )
    })
  })
}

///|
async test "provider does not match missing labels and starts the root of a multi-job workflow" {
  @test_support.with_repository_test_data((pool, root) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let alice = @identity.active_user_by_name(pool, "alice")
    let coordinator = Coordinator::new(pool)
    ignore(
      coordinator.create_provider(
        admin,
        "default",
        provider_secret,
        ["self-hosted", "linux"],
        [protocol_repo],
      ),
    )
    ignore(
      @test_support.workflow_commit(
        protocol_repo.git_dir(root),
        @test_support.single_job_workflow.replace_all(
          old="self-hosted, linux",
          new="self-hosted, linux, arm64",
        ),
      ),
    )
    let mismatch = create_run(
      pool, root, alice, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    assert_true(coordinator.claim(provider_secret, claim_request()) is None)
    ignore(
      @test_support.workflow_commit(
        protocol_repo.git_dir(root),
        sample_workflow,
      ),
    )
    let multi = create_run(
      pool, root, alice, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    let root_assignment = coordinator
      .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
      .unwrap()
    assert_eq(root_assignment.job.id, "build")
    ignore(
      coordinator.start(
        @protocol.parse_decimal(root_assignment.attempt_id).unwrap(),
        "c".repeat(64),
        1,
      ),
    )
    ignore(
      coordinator.complete(
        @protocol.parse_decimal(root_assignment.attempt_id).unwrap(),
        "c".repeat(64),
        completion(),
      ),
    )
    assert_eq(
      get_run(pool, alice, protocol_repo, mismatch.number).state,
      Queued,
    )
    assert_eq(get_run(pool, alice, protocol_repo, multi.number).state, Running)
  })
}

///|
async test "claim credentials cannot be promoted or reused and foreign attempts cannot read logs" {
  with_protocol_fixture((coordinator, pool, root, run, _, _) => {
    try
      ignore(
        coordinator.claim(
          provider_secret,
          claim_request(secret=provider_secret),
        ),
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("reused provider credential for attempt")
    }
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    try
      ignore(
        coordinator.create_provider(
          @identity.active_user_by_name(pool, "admin"),
          "promoted",
          attempt_secret,
          ["self-hosted", "linux"],
          [protocol_repo],
        ),
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("promoted attempt token to provider")
    }
    ignore(coordinator.start(id, attempt_secret, 1))
    let actor = @identity.active_user_by_name(pool, "alice")
    let other = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    try
      ignore(coordinator.read_logs(actor, protocol_repo, other.number, id))
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("logs crossed run scope")
    }
    let partial = attempt_secret[:20].to_owned()
    ignore(coordinator.append_log(id, attempt_secret, log_request(1L, partial)))
    assert_eq(
      coordinator.read_logs(actor, protocol_repo, run.number, id)[0].text,
      "",
    )
    ignore(coordinator.complete(id, attempt_secret, completion(last=1L)))
    assert_eq(
      coordinator
      .read_logs(actor, protocol_repo, run.number, id)
      .map(chunk => chunk.text)
      .join(""),
      "***",
    )
  })
}

///|
async test "MoonBit setup assignments and reruns retain the snapshotted toolchain version" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo = protocol_repo
    let actor = @identity.active_user_by_name(pool, "alice")
    let source =
      #|on: workflow_dispatch
      #|jobs:
      #|  check:
      #|    runs-on: [self-hosted, linux]
      #|    steps:
      #|      - uses: moonhub/checkout@v1
      #|      - uses: moonhub/setup-moonbit@v1
      #|        with: {version: 0.10.17+093cb8f9c}
      #|      - run: moon version --all
    let sha = @test_support.workflow_commit(repo.git_dir(root), source)
    let run = create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    assert_eq(
      run.definition.jobs[0].steps[1].moonbit_version,
      Some("0.10.17+093cb8f9c"),
    )
    ignore(
      @test_support.workflow_commit(
        repo.git_dir(root),
        source.replace_all(old="0.10.17+093cb8f9c", new="nightly"),
      ),
    )
    let coordinator = merge_check_provider(pool)
    let (assignment, token) = claim_dag_attempt(coordinator, provider_secret)
    assert_eq(assignment.version, @protocol.remote_assignment_version)
    assert_eq(assignment.commit_sha, sha)
    assert_eq(assignment.job.steps[0].uses, "moonhub/checkout@v1")
    assert_eq(assignment.job.steps[0].moonbit_version, "")
    assert_eq(assignment.job.steps[1].uses, "moonhub/setup-moonbit@v1")
    assert_eq(assignment.job.steps[1].moonbit_version, "0.10.17+093cb8f9c")
    assert_eq(assignment.job.steps[2].moonbit_version, "")
    let decoded : @protocol.Assignment = @json.from_json(
      ToJson::to_json(assignment),
    )
    assert_eq(decoded.job.steps[1].moonbit_version, "0.10.17+093cb8f9c")
    let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
    ignore(coordinator.start(id, token, 1))
    ignore(coordinator.complete(id, token, completion()))
    let rerun = rerun_run(pool, root, actor, repo, run.number)
    assert_eq(rerun.commit_sha, sha)
    assert_eq(rerun.workflow_source, source)
    assert_eq(
      ToJson::to_json(rerun.definition),
      ToJson::to_json(run.definition),
    )
    let (again, _) = claim_dag_attempt(coordinator, provider_secret)
    assert_eq(again.version, @protocol.remote_assignment_version)
    assert_eq(again.job.steps[1].moonbit_version, "0.10.17+093cb8f9c")
  })
}

///|
async test "action assignments preserve templates and allow cleanup after failure without allowing false success" {
  let source = @test_support.single_job_workflow +
    (
      #|
      #|      - id: clean
      #|        if: always()
      #|        run: echo cleanup
    )
  with_protocol_fixture(
    (coordinator, pool, _, run, _, _) => {
      let assignment = coordinator
        .claim(provider_secret, claim_request())
        .unwrap()
      assert_eq(assignment.version, @protocol.remote_assignment_version)
      assert_eq(assignment.job.steps[1].templates.get("if"), Some("always()"))
      let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
      ignore(
        coordinator.start(id, attempt_secret, 1, execution_id="e".repeat(32)),
      )
      let running : @protocol.StepRequest = {
        version: 1,
        step_id: "check",
        state: "running",
        exit_code: 0,
      }
      ignore(coordinator.update_step(id, attempt_secret, running))
      ignore(
        coordinator.update_step(id, attempt_secret, {
          ..running,
          state: "failure",
          exit_code: 3,
        }),
      )
      let cleanup = { ..running, step_id: "clean", }
      ignore(coordinator.update_step(id, attempt_secret, cleanup))
      ignore(
        coordinator.update_step(id, attempt_secret, {
          ..cleanup,
          state: "success",
        }),
      )
      try ignore(coordinator.complete(id, attempt_secret, completion())) catch {
        Conflict(_) => ()
        err => raise err
      } noraise {
        _ => fail("failed action job reported success")
      }
      ignore(
        coordinator.complete(
          id,
          attempt_secret,
          completion(conclusion="failure"),
        ),
      )
      assert_true(
        get_run(
          pool,
          @identity.active_user_by_name(pool, "alice"),
          protocol_repo,
          run.number,
        ).conclusion
        is Some(Failure),
      )
    },
    workflow=source,
  )
}

///|
async test "condition skips complete successfully but pending or failed steps cannot" {
  let source = @test_support.single_job_workflow + "\n        if: false"
  with_protocol_fixture(
    (coordinator, _, _, _, _, _) => {
      let assignment = coordinator
        .claim(provider_secret, claim_request())
        .unwrap()
      let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
      ignore(
        coordinator.start(id, attempt_secret, 1, execution_id="e".repeat(32)),
      )
      let running : @protocol.StepRequest = {
        version: 1,
        step_id: "check",
        state: "running",
        exit_code: 0,
      }
      ignore(coordinator.update_step(id, attempt_secret, running))
      ignore(
        coordinator.update_step(id, attempt_secret, {
          ..running,
          state: "skipped",
        }),
      )
      assert_eq(
        coordinator.complete(id, attempt_secret, completion()).conclusion,
        "success",
      )
    },
    workflow=source,
  )
}

///|
async test "new run-only workflows receive action runtime assignments" {
  with_protocol_fixture(
    (coordinator, _, _, _, _, _) => {
      let assignment = coordinator
        .claim(provider_secret, claim_request())
        .unwrap()
      assert_eq(assignment.version, @protocol.remote_assignment_version)
      assert_true(
        assignment.job.steps.all(step => {
          !step.remote && step.templates.is_empty()
        }),
      )
    },
    workflow=@test_support.single_job_workflow.replace_all(
      old="echo fixture",
      new="echo value=ready >> $GITHUB_OUTPUT",
    ),
  )
}

///|
async test "Windows providers claim only Windows jobs and reject legacy Linux workers" {
  @test_support.with_repository_test_data((pool, root) => {
    let source =
      #|name: Platforms
      #|on: workflow_dispatch
      #|jobs:
      #|  windows:
      #|    runs-on: [self-hosted, windows, x64]
      #|    steps:
      #|      - run: Write-Output windows
      #|  legacy:
      #|    runs-on: self-hosted
      #|    steps:
      #|      - run: echo linux
    ignore(@test_support.workflow_commit(protocol_repo.git_dir(root), source))
    let c = Coordinator::new(pool)
    let admin = @identity.active_user_by_name(pool, "admin")
    let windows = c.create_provider(
      admin,
      "windows",
      provider_secret,
      ["self-hosted", "windows", "x64"],
      [protocol_repo],
    )
    ignore(
      c.create_provider(
        admin,
        "linux",
        "c".repeat(64),
        ["self-hosted", "linux", "x64"],
        [protocol_repo],
      ),
    )
    ignore(
      create_run(
        pool,
        root,
        @identity.active_user_by_name(pool, "alice"),
        protocol_repo,
        "pipeline",
        ".github/workflows/build.yml",
      ),
    )
    // Old claim clients omit the OS: retain Linux semantics rather than silently
    // assigning Windows work to an old Linux worker after a provider relabel.
    try c.claim(provider_secret, claim_request()) catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("Legacy Linux worker claimed from a Windows provider")
    }
    let assignment = c
      .claim(provider_secret, { ..claim_request(), runner_os: Some("windows"), })
      .unwrap()
    assert_eq(assignment.job.id, "windows")
    assert_eq(assignment.job.runs_on, ["self-hosted", "windows", "x64"])
    assert_eq(
      c.claim("c".repeat(64), claim_request(secret="d".repeat(64))).unwrap().job.id,
      "legacy",
    )
    // A Windows worker must never pick up an implicit-Linux job.
    assert_true(
      c.claim(provider_secret, {
        ..claim_request(id="2", secret="e".repeat(64)),
        runner_os: Some("windows"),
      })
      is None,
    )
    try
      c.set_provider_labels(admin, windows.id, [
        "self-hosted", "linux", "windows",
      ])
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("Provider accepted conflicting operating systems")
    }
  })
}
