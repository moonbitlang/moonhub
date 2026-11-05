///|
async test "workflow concurrency retains a holder replaces pending work and survives coordinator restart" {
  let source = "concurrency: {group: Shared, cancel-in-progress: false}\n" +
    @test_support.single_job_workflow
  with_protocol_fixture(
    (c, pool, root, first, _, clock) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let a = c.claim(provider_secret, claim_request()).unwrap()
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      ignore(c.start(id, attempt_secret, 1))
      let pending = create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      )
      let latest = create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      )
      assert_true(
        get_run(pool, actor, protocol_repo, pending.number).conclusion
        is Some(Cancelled),
      )
      assert_true(
        c.claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        is None,
      )
      let restarted = Coordinator::new(pool, clock=() => clock.val)
      assert_eq(
        restarted.complete(id, attempt_secret, completion()).conclusion,
        "success",
      )
      let next = restarted
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap()
      assert_eq(next.run_id, latest.id.to_string())
      assert_true(
        get_run(pool, actor, protocol_repo, first.number).conclusion
        is Some(Success),
      )
    },
    workflow=source,
  )
}

///|
async test "cancel in progress fences old execution before admitting its successor" {
  let source = "concurrency: {group: '${{ github.workflow }}-${{ github.ref }}', cancel-in-progress: true}\n" +
    @test_support.single_job_workflow
  with_protocol_fixture(
    (c, pool, root, _, _, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let a = c.claim(provider_secret, claim_request()).unwrap()
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      ignore(c.start(id, attempt_secret, 1))
      let next = create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      )
      assert_true(c.heartbeat(id, attempt_secret, 1).cancel_requested)
      assert_true(
        c.claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        is None,
      )
      assert_eq(
        c.complete(id, attempt_secret, completion(conclusion="cancelled")).conclusion,
        "cancelled",
      )
      assert_eq(
        c
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap().run_id,
        next.id.to_string(),
      )
    },
    workflow=source,
  )
}

///|
async test "different concurrency groups and non concurrency workflows remain independent" {
  let source = "concurrency: '${{ github.ref }}'\n" +
    @test_support.single_job_workflow
  with_protocol_fixture(
    (c, pool, root, _, _, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let dir = protocol_repo.git_dir(root)
      ignore(
        @gitops.merge_git(dir, [
          "update-ref", "refs/heads/other", "refs/heads/pipeline",
        ]),
      )
      let other = create_run(
        pool, root, actor, protocol_repo, "other", ".github/workflows/build.yml",
      )
      pool.with_client(client => {
        let admitted : Bool = client
          .query_one(
            "SELECT admitted FROM pipeline_run_schedule WHERE run_id=?",
            params=[other.id],
          )
          .get_name("admitted")
        assert_true(admitted)
      })
      ignore(c.claim(provider_secret, claim_request()))
    },
    workflow=source,
  )
}

///|
let matrix_schedule_workflow : String =
  #|on: workflow_dispatch
  #|jobs:
  #|  build:
  #|    runs-on: [self-hosted, linux]
  #|    strategy:
  #|      max-parallel: 1
  #|      matrix: {target: [native, js, wasm]}
  #|    steps:
  #|      - run: echo '${{ matrix.target }}'
  #|  after:
  #|    needs: build
  #|    runs-on: [self-hosted, linux]
  #|    steps: [{run: echo done}]

///|
async test "matrix max parallel is atomic across providers and needs waits for every instance" {
  with_protocol_fixture(
    (c, pool, _, run, _, _) => {
      let admin = @identity.active_user_by_name(pool, "admin")
      ignore(
        c.create_provider(
          admin,
          "second",
          "c".repeat(64),
          ["self-hosted", "linux"],
          [protocol_repo],
        ),
      )
      let a = c.claim(provider_secret, claim_request()).unwrap()
      assert_eq(a.job.matrix.get("target"), Some(Json::string("native")))
      assert_true(
        c.claim("c".repeat(64), claim_request(secret="d".repeat(64))) is None,
      )
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      ignore(c.start(id, attempt_secret, 1))
      ignore(c.complete(id, attempt_secret, completion()))
      let second = c
        .claim("c".repeat(64), claim_request(id="2", secret="e".repeat(64)))
        .unwrap()
      assert_eq(second.job.matrix.get("target"), Some(Json::string("js")))
      let id = @protocol.parse_decimal(second.attempt_id).unwrap()
      ignore(c.start(id, "e".repeat(64), 1))
      ignore(c.complete(id, "e".repeat(64), completion()))
      let third = c
        .claim(provider_secret, claim_request(id="3", secret="f".repeat(64)))
        .unwrap()
      assert_eq(third.job.matrix.get("target"), Some(Json::string("wasm")))
      let actor = @identity.active_user_by_name(pool, "alice")
      assert_true(
        list_jobs(pool, actor, protocol_repo, run.number)
        .iter()
        .find_first(job => job.job_key == "after")
        .unwrap().state
        is Waiting,
      )
      let id = @protocol.parse_decimal(third.attempt_id).unwrap()
      ignore(c.start(id, "f".repeat(64), 1))
      ignore(c.complete(id, "f".repeat(64), completion()))
      assert_eq(
        c
        .claim(provider_secret, claim_request(id="4", secret="1".repeat(64)))
        .unwrap().job.id,
        "after",
      )
    },
    workflow=matrix_schedule_workflow,
  )
}

///|
async test "matrix fail fast cancels only siblings and failure does not turn into cancellation" {
  for fail_fast in [true, false] {
    let source = matrix_schedule_workflow.replace_all(
        old="max-parallel: 1",
        new="max-parallel: 1\n      fail-fast: " + fail_fast.to_string(),
      ) +
      "\n  unrelated:\n    runs-on: [self-hosted, linux]\n    steps: [{run: echo independent}]\n"
    with_protocol_fixture(
      (c, pool, _, run, _, _) => {
        let a = c.claim(provider_secret, claim_request()).unwrap()
        let id = @protocol.parse_decimal(a.attempt_id).unwrap()
        ignore(c.start(id, attempt_secret, 1))
        ignore(c.complete(id, attempt_secret, completion(conclusion="failure")))
        let actor = @identity.active_user_by_name(pool, "alice")
        let jobs = list_jobs(pool, actor, protocol_repo, run.number)
        let siblings = jobs.filter(job => {
          job.job_key.has_prefix("build[") && job.job_key != "build[1]"
        })
        assert_true(
          siblings.all(job => {
            if fail_fast {
              job.conclusion is Some(Cancelled)
            } else {
              job.state is Queued
            }
          }),
        )
        let next = c
          .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
          .unwrap()
        assert_eq(next.job.id, if fail_fast { "unrelated" } else { "build" })
        if fail_fast {
          let id = @protocol.parse_decimal(next.attempt_id).unwrap()
          ignore(c.start(id, "c".repeat(64), 1))
          ignore(c.complete(id, "c".repeat(64), completion()))
          assert_true(
            get_run(pool, actor, protocol_repo, run.number).conclusion
            is Some(Failure),
          )
        }
      },
      workflow=source,
    )
  }
}

///|
async test "matrix fail fast cancels a running sibling and does not strand group capacity" {
  let source = matrix_schedule_workflow.replace_all(
    old="max-parallel: 1",
    new="max-parallel: 2",
  )
  with_protocol_fixture(
    (c, pool, _, run, _, _) => {
      let admin = @identity.active_user_by_name(pool, "admin")
      ignore(
        c.create_provider(
          admin,
          "parallel",
          "c".repeat(64),
          ["self-hosted", "linux"],
          [protocol_repo],
        ),
      )
      let a = c.claim(provider_secret, claim_request()).unwrap()
      let aid = @protocol.parse_decimal(a.attempt_id).unwrap()
      let b = c
        .claim("c".repeat(64), claim_request(secret="d".repeat(64)))
        .unwrap()
      let bid = @protocol.parse_decimal(b.attempt_id).unwrap()
      ignore(c.start(aid, attempt_secret, 1))
      ignore(c.start(bid, "d".repeat(64), 1))
      ignore(c.complete(aid, attempt_secret, completion(conclusion="failure")))
      assert_true(c.heartbeat(bid, "d".repeat(64), 1).cancel_requested)
      ignore(c.complete(bid, "d".repeat(64), completion(conclusion="success")))
      let actor = @identity.active_user_by_name(pool, "alice")
      assert_true(
        get_run(pool, actor, protocol_repo, run.number).conclusion
        is Some(Failure),
      )
      assert_true(
        c.claim(provider_secret, claim_request(id="2", secret="e".repeat(64)))
        is None,
      )
    },
    workflow=source,
  )
}

///|
async test "PR concurrency ref separates different pull requests from the same source branch" {
  let source = "concurrency: {group: '${{ github.workflow }}-${{ github.ref }}', cancel-in-progress: true}\n" +
    pull_request_workflow
  with_merge_check_fixture(
    (pool, root, scope, actor, mr) => {
      let dir = protocol_repo.git_dir(root)
      let other_base = @gitops.branch_sha(dir, "master")
      ignore(
        @gitops.merge_git(dir, ["update-ref", "refs/heads/release", other_base]),
      )
      let other = @collaboration.create_merge_request(
        pool, scope, dir, actor, "other target", "", "feature", "release", false,
      )
      poll_merge_checks(pool, root)
      assert_true(run_next_merge_check(pool, root))
      let runs = list_runs(pool, actor, protocol_repo)
      assert_eq(runs.length(), 2)
      assert_true(runs.all(run => run.conclusion is None))
      pool.with_client(client => {
        let groups = client.query_all(
          "SELECT group_key,admitted FROM pipeline_run_schedule ORDER BY run_id",
        )
        assert_eq(groups.length(), 2)
        assert_true(groups.all(row => (row.get_name("admitted") : Bool)))
        assert_true(
          (groups[0].get_name("group_key") : String) !=
          (groups[1].get_name("group_key") : String),
        )
      })
      assert_true(other.number != mr.number)
    },
    workflow=source,
    required=false,
  )
}

///|
async test "expired concurrency holders release their persisted group slot" {
  let source = "concurrency: Shared\n" + @test_support.single_job_workflow
  with_protocol_fixture(
    (c, pool, root, _, _, clock) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      ignore(c.claim(provider_secret, claim_request()))
      let next = create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      )
      assert_eq(
        c.queue_reasons(actor, protocol_repo, next.number).get("build"),
        Some(WaitingConcurrency),
      )
      clock.val += @protocol.lease_ms + 1L
      assert_eq(c.expire_attempts(), 1)
      let fresh = Coordinator::new(pool, clock=() => clock.val)
      assert_eq(
        fresh
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap().run_id,
        next.id.to_string(),
      )
    },
    workflow=source,
  )
}
