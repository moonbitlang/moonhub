///|
let dynamic_schedule_workflow : String =
  #|on: workflow_dispatch
  #|jobs:
  #|  prepare:
  #|    runs-on: self-hosted
  #|    outputs: {matrix: '${{ steps.plan.outputs.matrix }}'}
  #|    steps: [{id: plan, run: echo plan}]
  #|  build:
  #|    needs: prepare
  #|    runs-on: ${{ matrix.labels }}
  #|    continue-on-error: ${{ matrix.experimental }}
  #|    strategy:
  #|      fail-fast: false
  #|      matrix: ${{ fromJSON(needs.prepare.outputs.matrix) }}
  #|    outputs: {target: '${{ matrix.target }}'}
  #|    steps: [{run: 'echo ${{ matrix.target }}'}]
  #|  after:
  #|    needs: build
  #|    runs-on: self-hosted
  #|    steps: [{run: 'echo ${{ needs.build.outputs.target }}'}]

///|
let dynamic_schedule_rows : String =
  #|{"include":[{"target":"stable","labels":["self-hosted","linux"],"experimental":false},{"target":"edge","labels":["self-hosted","linux"],"experimental":true}]}

///|
async test "dynamic matrices persist expansion and effective failures across restart and duplicate completion" {
  with_protocol_fixture(
    (c, pool, _, run, _, clock) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      assert_eq(
        @runtime.list_jobs(pool, actor, protocol_repo, run.number).length(),
        3,
      )
      let producer = c.runtime.claim(provider_secret, claim_request()).unwrap()
      let completion = complete_output_job(c, producer, attempt_secret, {
        "matrix": dynamic_schedule_rows,
      })
      ignore(
        c.runtime.complete(
          @protocol.parse_decimal(producer.attempt_id).unwrap(),
          attempt_secret,
          completion,
        ),
      )
      let restarted = test_services(pool, clock=() => clock.val)
      let stable = restarted.runtime.claim(
        provider_secret,
        claim_request(id="2", secret="c".repeat(64)),
      )
      assert_true(
        stable is Some(_),
        msg=@runtime.list_jobs(pool, actor, protocol_repo, run.number)
          .map(job => job.job_key + ": " + job.scheduling_error)
          .join("; "),
      )
      let stable = stable.unwrap()
      assert_eq(stable.job.id, "build")
      assert_eq(stable.job.matrix.get("target"), Some(Json::string("stable")))
      ignore(
        complete_output_job(restarted, stable, "c".repeat(64), {
          "target": "stable",
        }),
      )
      let edge = restarted.runtime
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap()
      assert_eq(edge.job.id, "build")
      ignore(
        complete_output_job(
          restarted,
          edge,
          "d".repeat(64),
          { "target": "edge" },
          conclusion="failure",
        ),
      )
      let after = restarted.runtime.claim(
        provider_secret,
        claim_request(id="4", secret="e".repeat(64)),
      )
      assert_true(
        after is Some(_),
        msg="matrix barrier did not release downstream",
      )
      let after = after.unwrap()
      assert_eq(after.job.id, "after")
      assert_true(
        after.job.needs.get("build")
        is Some(
          { "result": "success", "outputs": { "target": "edge", .. }, .. },
        ),
      )
      ignore(complete_output_job(restarted, after, "e".repeat(64), Map([])))
      let jobs = @runtime.list_jobs(pool, actor, protocol_repo, run.number)
      assert_eq(jobs.length(), 5)
      let edge = jobs
        .iter()
        .find_first(job => job.job_key == "build[2]")
        .unwrap()
      assert_true(edge.conclusion is Some(Success))
      assert_true(edge.actual_conclusion is Some(Failure))
      assert_true(
        @runtime.get_run(pool, actor, protocol_repo, run.number).conclusion
        is Some(Success),
      )
      assert_eq(
        ToJson::to_json(
          @runtime.get_run(pool, actor, protocol_repo, run.number).definition,
        ),
        ToJson::to_json(run.definition),
      )
      pool.with_client(client => {
        assert_eq(
          (
            client
            .query_one("SELECT count(*) AS n FROM pipeline_matrix_expansion")
            .get_name("n") : Int64),
          1L,
        )
        assert_eq(
          (
            client
            .query_one("SELECT count(*) AS n FROM pipeline_job_definition")
            .get_name("n") : Int64),
          2L,
        )
      })
    },
    workflow=dynamic_schedule_workflow,
  )
}

///|
async test "dynamic failed-only reruns reuse successful children and their outputs" {
  with_protocol_fixture(
    (c, pool, root, run, _, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let producer = c.runtime.claim(provider_secret, claim_request()).unwrap()
      ignore(
        complete_output_job(c, producer, attempt_secret, {
          "matrix": dynamic_schedule_rows,
        }),
      )
      for index in 0..<2 {
        let token = if index == 0 { "c".repeat(64) } else { "d".repeat(64) }
        let job = c.runtime
          .claim(
            provider_secret,
            claim_request(id=(index + 2).to_string(), secret=token),
          )
          .unwrap()
        ignore(
          complete_output_job(
            c,
            job,
            token,
            { "target": if index == 0 { "stable" } else { "edge" } },
            conclusion=if index == 0 { "failure" } else { "success" },
          ),
        )
      }
      let again = rerun_run(
        pool,
        root,
        actor,
        protocol_repo,
        run.number,
        failed_only=true,
      )
      let retry = c.runtime
        .claim(provider_secret, claim_request(id="4", secret="e".repeat(64)))
        .unwrap()
      assert_eq(retry.job.id, "build")
      let jobs = @runtime.list_jobs(pool, actor, protocol_repo, again.number)
      assert_eq(
        jobs.iter().find_first(job => job.job_key == "build[2]").unwrap().reused_from,
        Some(run.number),
      )
      ignore(
        complete_output_job(c, retry, "e".repeat(64), {
          "target": "stable-retry",
        }),
      )
      let after = c.runtime
        .claim(provider_secret, claim_request(id="5", secret="f".repeat(64)))
        .unwrap()
      assert_eq(after.job.id, "after")
      assert_true(
        after.job.needs.get("build")
        is Some({ "outputs": { "target": "stable-retry", .. }, .. }),
      )
      ignore(complete_output_job(c, after, "f".repeat(64), Map([])))
      assert_true(
        @runtime.get_run(pool, actor, protocol_repo, again.number).conclusion
        is Some(Success),
      )
    },
    workflow=dynamic_schedule_workflow,
  )
}

///|
async test "invalid dynamic matrix data fails the consumer without rolling back its producer" {
  for
    value in [
      "not json", "[]", "{\"include\":[]}", "{\"__proto__\":{}}", "{\"x\":[1],\"y\":[1]}",
    ] {
    with_protocol_fixture(
      (c, pool, _, run, _, _) => {
        let producer = c.runtime
          .claim(provider_secret, claim_request())
          .unwrap()
        ignore(
          complete_output_job(c, producer, attempt_secret, { "matrix": value }),
        )
        let actor = @identity.active_user_by_name(pool, "alice")
        let jobs = @runtime.list_jobs(pool, actor, protocol_repo, run.number)
        assert_eq(jobs.length(), 3)
        assert_true(jobs[0].conclusion is Some(Success))
        assert_true(jobs[1].conclusion is Some(Failure))
        assert_true(jobs[2].conclusion is Some(Skipped))
        assert_true(
          @runtime.get_run(pool, actor, protocol_repo, run.number).conclusion
          is Some(Failure),
        )
      },
      workflow=dynamic_schedule_workflow,
    )
  }
}

///|
async test "workflow queue max persists FIFO and cancels the 101st waiter" {
  with_protocol_fixture(
    (c, pool, root, run, _, clock) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let holder = c.runtime.claim(provider_secret, claim_request()).unwrap()
      ignore(
        c.runtime.start(
          @protocol.parse_decimal(holder.attempt_id).unwrap(),
          attempt_secret,
          1,
        ),
      )
      let pending : Array[@runtime.Run] = []
      for _ in 0..<101 {
        pending.push(
          create_run(
            pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
          ),
        )
      }
      assert_true(
        @runtime.get_run(pool, actor, protocol_repo, pending[100].number).conclusion
        is Some(Cancelled),
      )
      for item in pending[:100] {
        assert_true(
          @runtime.get_run(pool, actor, protocol_repo, item.number).state
          is Queued,
        )
      }
      let restarted = test_services(pool, clock=() => clock.val)
      ignore(
        restarted.runtime.complete(
          @protocol.parse_decimal(holder.attempt_id).unwrap(),
          attempt_secret,
          completion(),
        ),
      )
      let first = restarted.runtime
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap()
      assert_eq(first.run_id, pending[0].id.to_string())
      ignore(complete_output_job(restarted, first, "c".repeat(64), Map([])))
      let second = restarted.runtime
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap()
      assert_eq(second.run_id, pending[1].id.to_string())
      assert_true(
        @runtime.get_run(pool, actor, protocol_repo, run.number).conclusion
        is Some(Success),
      )
    },
    workflow="concurrency: {group: fifo, queue: max}\n" +
      @test_support.single_job_workflow,
  )
}

///|
async test "job concurrency cancellation retains its slot until the worker is fenced" {
  let workflow = @test_support.single_job_workflow +
    "\n    concurrency: {group: shared-job, cancel-in-progress: true}\n"
  with_protocol_fixture(
    (c, pool, root, _, _, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let holder = c.runtime.claim(provider_secret, claim_request()).unwrap()
      let id = @protocol.parse_decimal(holder.attempt_id).unwrap()
      ignore(c.runtime.start(id, attempt_secret, 1))
      let next = create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      )
      assert_true(c.runtime.heartbeat(id, attempt_secret, 1).cancel_requested)
      assert_true(
        c.runtime.claim(
          provider_secret,
          claim_request(id="2", secret="c".repeat(64)),
        )
        is None,
      )
      ignore(
        c.runtime.complete(
          id,
          attempt_secret,
          completion(conclusion="cancelled"),
        ),
      )
      assert_eq(
        c.runtime
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap().run_id,
        next.id.to_string(),
      )
    },
    workflow~,
  )
}

///|
async test "allowed matrix failures neither fail fast nor fail dependencies" {
  let workflow =
    #|on: workflow_dispatch
    #|jobs:
    #|  build:
    #|    runs-on: self-hosted
    #|    continue-on-error: ${{ matrix.experimental }}
    #|    strategy: {matrix: {experimental: [true, false]}}
    #|    steps: [{run: echo build}]
    #|  after:
    #|    needs: build
    #|    runs-on: self-hosted
    #|    steps: [{run: echo after}]
  with_protocol_fixture(
    (c, pool, root, run, _, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let first = c.runtime.claim(provider_secret, claim_request()).unwrap()
      ignore(
        complete_output_job(
          c,
          first,
          attempt_secret,
          Map([]),
          conclusion="failure",
        ),
      )
      let second = c.runtime
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap()
      assert_eq(second.job.id, "build")
      ignore(complete_output_job(c, second, "c".repeat(64), Map([])))
      let after = c.runtime
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap()
      assert_true(
        after.job.needs.get("build") is Some({ "result": "success", .. }),
      )
      ignore(complete_output_job(c, after, "d".repeat(64), Map([])))
      assert_true(
        @runtime.get_run(pool, actor, protocol_repo, run.number).conclusion
        is Some(Success),
      )
      let again = rerun_run(
        pool,
        root,
        actor,
        protocol_repo,
        run.number,
        failed_only=true,
      )
      assert_eq(
        @runtime.list_jobs(pool, actor, protocol_repo, again.number)[1].reused_from,
        Some(run.number),
      )
      assert_eq(
        c.runtime
        .claim(provider_secret, claim_request(id="4", secret="e".repeat(64)))
        .unwrap().job.id,
        "build",
      )
    },
    workflow~,
  )
}

///|
async test "job concurrency pending replacement uses the shared namespace and reports waiting" {
  let workflow = @test_support.single_job_workflow +
    "\n    concurrency: shared-job\n"
  with_protocol_fixture(
    (c, pool, root, _, _, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let holder = c.runtime.claim(provider_secret, claim_request()).unwrap()
      let id = @protocol.parse_decimal(holder.attempt_id).unwrap()
      ignore(c.runtime.start(id, attempt_secret, 1))
      let replaced = create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      )
      let latest = create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      )
      assert_true(
        @runtime.list_jobs(pool, actor, protocol_repo, replaced.number)[0].conclusion
        is Some(Cancelled),
      )
      assert_true(
        c.runtime
        .queue_reasons(actor, protocol_repo, latest.number)
        .values()
        .all(reason => reason is @runtime.WaitingConcurrency),
      )
      ignore(c.runtime.complete(id, attempt_secret, completion()))
      assert_eq(
        c.runtime
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap().run_id,
        latest.id.to_string(),
      )
    },
    workflow~,
  )
}

///|
async test "job FIFO admission survives restart while unrelated work remains eligible" {
  let workflow =
    #|on: workflow_dispatch
    #|jobs:
    #|  first:
    #|    runs-on: self-hosted
    #|    concurrency: {group: moonhub-production, queue: max, cancel-in-progress: false}
    #|    steps: [{run: echo first}]
    #|  second:
    #|    runs-on: self-hosted
    #|    concurrency: {group: moonhub-production, queue: max, cancel-in-progress: false}
    #|    steps: [{run: echo second}]
    #|  independent:
    #|    runs-on: self-hosted
    #|    continue-on-error: true
    #|    steps: [{run: echo independent}]
  with_protocol_fixture(
    (c, pool, _, _, _, clock) => {
      let admin = @identity.active_user_by_name(pool, "admin")
      ignore(
        c.runtime.create_provider(
          admin,
          "second",
          "c".repeat(64),
          ["self-hosted", "linux"],
          [protocol_repo],
        ),
      )
      let first = c.runtime.claim(provider_secret, claim_request()).unwrap()
      assert_eq(first.job.id, "first")
      let id = @protocol.parse_decimal(first.attempt_id).unwrap()
      ignore(c.runtime.start(id, attempt_secret, 1))
      let independent = c.runtime
        .claim("c".repeat(64), claim_request(id="2", secret="d".repeat(64)))
        .unwrap()
      assert_eq(independent.job.id, "independent")
      ignore(
        complete_output_job(
          c,
          independent,
          "d".repeat(64),
          Map([]),
          conclusion="failure",
        ),
      )
      let restarted = test_services(pool, clock=() => clock.val)
      assert_true(
        restarted.runtime.claim(
          "c".repeat(64),
          claim_request(id="3", secret="e".repeat(64)),
        )
        is None,
      )
      ignore(restarted.runtime.complete(id, attempt_secret, completion()))
      let second = restarted.runtime
        .claim("c".repeat(64), claim_request(id="4", secret="f".repeat(64)))
        .unwrap()
      assert_eq(second.job.id, "second")
      ignore(complete_output_job(restarted, second, "f".repeat(64), Map([])))
    },
    workflow~,
  )
}

///|
async test "failed-only reruns freeze expanded matrices while full reruns reevaluate them" {
  let source =
    #|on: workflow_dispatch
    #|jobs:
    #|  build:
    #|    runs-on: self-hosted
    #|    strategy:
    #|      fail-fast: false
    #|      matrix: ${{ github.run_attempt == 1 && fromJSON('{"target":["stable","retry"]}') || fromJSON('{"target":["changed","retry"]}') }}
    #|    steps: [{run: 'echo ${{ matrix.target }}'}]
  with_protocol_fixture(
    (c, pool, root, run, _, _) => {
      let first = c.runtime.claim(provider_secret, claim_request()).unwrap()
      assert_eq(first.job.matrix.get("target"), Some(Json::string("stable")))
      ignore(complete_output_job(c, first, attempt_secret, Map([])))
      let failed = c.runtime
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap()
      ignore(
        complete_output_job(
          c,
          failed,
          "c".repeat(64),
          Map([]),
          conclusion="failure",
        ),
      )
      let actor = @identity.active_user_by_name(pool, "alice")
      let again = rerun_run(
        pool,
        root,
        actor,
        protocol_repo,
        run.number,
        failed_only=true,
      )
      let retry = c.runtime
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap()
      assert_eq(retry.job.matrix.get("target"), Some(Json::string("retry")))
      let jobs = @runtime.list_jobs(pool, actor, protocol_repo, again.number)
      assert_eq(
        jobs.iter().find_first(job => job.job_key == "build[1]").unwrap().reused_from,
        Some(run.number),
      )
      pool.with_client(tx => {
        let saved : String = tx
          .query_one(
            "SELECT e.matrix_json FROM pipeline_matrix_expansion e JOIN pipeline_job j ON j.id=e.job_id WHERE j.run_id=? AND j.job_key='build'",
            params=[again.id],
          )
          .get_name("matrix_json")
        assert_eq(
          @json.parse(saved),
          ({ "target": ["stable", "retry"] } : Json),
        )
      })
      ignore(complete_output_job(c, retry, "d".repeat(64), Map([])))
      ignore(rerun_run(pool, root, actor, protocol_repo, again.number))
      let fresh = c.runtime
        .claim(provider_secret, claim_request(id="4", secret="e".repeat(64)))
        .unwrap()
      assert_eq(fresh.job.matrix.get("target"), Some(Json::string("changed")))
    },
    workflow=source,
  )
}
