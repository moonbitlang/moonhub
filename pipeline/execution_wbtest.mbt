///|
let protocol_repo : @domain.RepoId = { owner: "alice", name: "demo", }

///|
let provider_secret : String = "a".repeat(64)

///|
let attempt_secret : String = "b".repeat(64)

///|
fn claim_request(
  id? : String = "1",
  secret? : String = attempt_secret,
) -> @protocol.ClaimRequest {
  { version: 1, request_id: id.repeat(32), attempt_token: secret, }
}

///|
fn log_request(sequence : Int64, text : String) -> @protocol.LogRequest {
  { version: 1, sequence, step_id: "check", stream: "stdout", text, }
}

///|
fn completion(
  conclusion? : String = "success",
  last? : Int64 = 0L,
) -> @protocol.CompleteRequest {
  { version: 1, conclusion, last_log_sequence: last, }
}

///|
async fn with_protocol_fixture(
  f : async (Coordinator, @database.Database, String, Run, Provider, Ref[Int64]) -> Unit,
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
    ignore(
      @test_support.workflow_commit(
        protocol_repo.git_dir(root),
        @test_support.single_job_workflow,
      ),
    )
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
async test "claim allocation is idempotent across coordinator restarts and does not leak credentials" {
  with_protocol_fixture((coordinator, pool, _, run, _, clock) => {
    let request = claim_request()
    let first = coordinator.claim(provider_secret, request).unwrap()
    let restarted = Coordinator::new(pool, clock=() => clock.val)
    let replay = restarted.claim(provider_secret, request).unwrap()
    assert_eq(ToJson::to_json(first), ToJson::to_json(replay))
    assert_eq(first.run_id, run.id)
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
    try ignore(restarted.start(first.attempt_id, provider_secret, 1)) catch {
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
      first.job_id,
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
    let id = coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id
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
        after=chunks.last().unwrap().id,
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
    let id = coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id
    let lease = clock.val + @protocol.lease_ms
    clock.val += 30000L
    assert_eq(
      coordinator.heartbeat(id, attempt_secret, 1).lease_until_ms,
      lease,
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
    assert_eq(fresh.run_id, next.id)
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
    try ignore(coordinator.start(fresh.attempt_id, attempt_secret, 1)) catch {
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
    let id = coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id
    let start = coordinator.start(id, attempt_secret, 1)
    clock.val += 30000L
    let again = coordinator.start(id, attempt_secret, 1)
    assert_eq(again.lease_until_ms, start.lease_until_ms)
    assert_eq(
      coordinator.heartbeat(id, attempt_secret, 1).lease_until_ms,
      start.lease_until_ms,
    )
    clock.val = start.lease_until_ms
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
    let id = coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id
    ignore(coordinator.start(id, attempt_secret, 1))
    coordinator.cancel_run(actor, protocol_repo, run.number)
    let first = coordinator.heartbeat(id, attempt_secret, 1)
    assert_true(first.cancel_requested)
    assert_eq(first.lease_until_ms, clock.val + @protocol.cancel_grace_ms)
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
    let id = coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id
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
    let id = coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id
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
      let id = coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id
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
    let id = coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id
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
    assert_eq(coordinator.heartbeat(id, attempt_secret, 1).log_sequence, 128L)
  })
}

///|
async test "claim logs and cancellation survive closing and reopening the durable database" {
  with_protocol_fixture((coordinator, pool, root, run, _, clock) => {
    let assignment = coordinator
      .claim(provider_secret, claim_request())
      .unwrap()
    ignore(coordinator.start(assignment.attempt_id, attempt_secret, 1))
    ignore(
      coordinator.append_log(
        assignment.attempt_id,
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
          assignment.attempt_id,
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
      assert_eq(retry.attempt_id, assignment.attempt_id)
      assert_eq(retry.state, "running")
      ignore(
        restored.append_log(
          retry.attempt_id,
          attempt_secret,
          log_request(2L, "two\n"),
        ),
      )
      let actor = @identity.active_user_by_name(reopened, "alice")
      assert_eq(
        restored
        .read_logs(actor, protocol_repo, run.number, retry.attempt_id)
        .map(chunk => chunk.text)
        .join(""),
        "one\ntwo\n",
      )
      restored.cancel_run(actor, protocol_repo, run.number)
      let third = Coordinator::new(reopened, clock=() => clock.val)
      assert_true(
        third.heartbeat(retry.attempt_id, attempt_secret, 1).cancel_requested,
      )
      assert_eq(
        third.complete(
          retry.attempt_id,
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
async test "provider does not match missing labels or partially execute a multi-job workflow" {
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
    assert_true(coordinator.claim(provider_secret, claim_request()) is None)
    assert_eq(
      get_run(pool, alice, protocol_repo, mismatch.number).state,
      Queued,
    )
    assert_eq(get_run(pool, alice, protocol_repo, multi.number).state, Queued)
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
    let id = coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id
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
      partial,
    )
  })
}
