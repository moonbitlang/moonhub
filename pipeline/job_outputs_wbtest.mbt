///|
let output_workflow : String =
  #|on: workflow_dispatch
  #|jobs:
  #|  prepare:
  #|    runs-on: self-hosted
  #|    outputs:
  #|      version: ${{ steps.release.outputs.version }}
  #|      secret: ${{ steps.release.outputs.secret }}
  #|    steps: [{id: release, run: echo prepare}]
  #|  build:
  #|    needs: prepare
  #|    if: needs.prepare.outputs.version == '1.2.3'
  #|    runs-on: self-hosted
  #|    steps:
  #|      - id: build
  #|        run: echo ${{ needs.prepare.outputs.version }}
  #|  skip:
  #|    needs: prepare
  #|    if: needs.prepare.outputs.version == 'other'
  #|    runs-on: self-hosted
  #|    steps: [{run: echo must-not-run}]

///|
fn complete_output_job(
  c : Coordinator,
  a : @protocol.Assignment,
  token : String,
  outputs : Map[String, String],
  conclusion~ : String = "success",
) -> @protocol.CompleteRequest raise {
  let id = @protocol.parse_decimal(a.attempt_id).unwrap()
  ignore(c.start(id, token, 1, execution_id="1".repeat(32)))
  for step in a.job.steps {
    ignore(
      c.update_step(id, token, {
        version: 1,
        step_id: step.id,
        state: "running",
        exit_code: 0,
      }),
    )
    ignore(
      c.update_step(id, token, {
        version: 1,
        step_id: step.id,
        state: if conclusion == "failure" {
          "failure"
        } else {
          "success"
        },
        exit_code: if conclusion == "failure" {
          1
        } else {
          0
        },
      }),
    )
  }
  let request = { ..completion(conclusion~), outputs, }
  ignore(c.complete(id, token, request)) catch {
    @domain.BadRequest(message~) => fail(message)
    err => raise err
  }
  request
}

///|
async test "job outputs publish atomically filter delivered secrets and bind idempotent completion" {
  with_protocol_fixture(
    (c, pool, _, run, _, _) => {
      let a = c.claim(provider_secret, claim_request()).unwrap()
      assert_eq(a.version, @protocol.dataflow_assignment_version)
      assert_eq(a.job.id, "prepare")
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      pool.with_client(client => {
        ignore(
          client.execute(
            "INSERT INTO pipeline_secret_delivery(attempt_id,step_id,env_name,value) VALUES(?,?,?,?)",
            params=[id, "release", "TOKEN", "never-publish"],
          ),
        )
      })
      let request = complete_output_job(c, a, attempt_secret, {
        "version": "1.2.3",
        "secret": "prefix-never-publish",
      })
      assert_eq(c.complete(id, attempt_secret, request).conclusion, "success")
      assert_eq(
        c.complete(id, attempt_secret, {
          ..request,
          outputs: { "secret": "prefix-never-publish", "version": "1.2.3" },
        }).conclusion,
        "success",
      )
      try
        ignore(
          c.complete(id, attempt_secret, {
            ..request,
            outputs: { "version": "changed" },
          }),
        )
      catch {
        Conflict(_) => ()
        err => raise err
      } noraise {
        _ => fail("changed output completion accepted")
      }
      let b = c
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap()
      assert_eq(b.job.id, "build")
      assert_eq(
        b.job.needs.get("prepare"),
        Some(
          ({ "result": "success", "outputs": { "version": "1.2.3" } } : Json),
        ),
      )
      assert_true(b.job.needs.get("skip") is None)
      ignore(complete_output_job(c, b, "c".repeat(64), Map([])))
      let jobs = list_jobs(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        protocol_repo,
        run.number,
      )
      assert_true(
        jobs.iter().find_first(job => job.job_key == "skip").unwrap().conclusion
        is Some(Skipped),
      )
      pool.with_client(client => {
        assert_eq(
          (
            client
            .query_one("SELECT COUNT(*) AS count FROM pipeline_job_output")
            .get_name("count") : Int64),
          1L,
        )
        assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
      })
    },
    workflow=output_workflow,
  )
}

///|
async test "job conditions propagate ancestor failure but explicit cleanup may run" {
  let workflow =
    #|on: workflow_dispatch
    #|jobs:
    #|  fail:
    #|    runs-on: self-hosted
    #|    steps: [{id: fail, run: exit 1}]
    #|  cleanup:
    #|    needs: fail
    #|    if: always()
    #|    runs-on: self-hosted
    #|    steps: [{id: cleanup, run: echo cleanup}]
    #|  default:
    #|    needs: cleanup
    #|    runs-on: self-hosted
    #|    steps: [{run: echo should-skip}]
    #|  diagnose:
    #|    needs: cleanup
    #|    if: failure()
    #|    runs-on: self-hosted
    #|    steps: [{id: diagnose, run: echo diagnose}]
  with_protocol_fixture(
    (c, pool, _, run, _, _) => {
      let a = c.claim(provider_secret, claim_request()).unwrap()
      ignore(
        complete_output_job(c, a, attempt_secret, Map([]), conclusion="failure"),
      )
      let b = c
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap()
      assert_eq(b.job.id, "cleanup")
      assert_eq(
        b.job.needs.get("fail"),
        Some(({ "result": "failure", "outputs": {} } : Json)),
      )
      ignore(complete_output_job(c, b, "c".repeat(64), Map([])))
      let d = c
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap()
      assert_eq(d.job.id, "diagnose")
      assert_true(d.job.needs.get("fail") is None)
      ignore(complete_output_job(c, d, "d".repeat(64), Map([])))
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
    workflow~,
  )
}

///|
async test "matrix needs aggregates outputs by completion order and waits for all instances" {
  let workflow =
    #|on: workflow_dispatch
    #|jobs:
    #|  build:
    #|    strategy: {fail-fast: false, matrix: {target: [a, b, c]}}
    #|    runs-on: self-hosted
    #|    outputs: {shared: "${{ steps.build.outputs.value }}"}
    #|    steps: [{id: build, run: echo build}]
    #|  after:
    #|    needs: build
    #|    runs-on: self-hosted
    #|    steps: [{run: echo after}]
  with_protocol_fixture(
    (c, pool, _, _, _, _) => {
      ignore(
        c.create_provider(
          @identity.active_user_by_name(pool, "admin"),
          "second",
          "c".repeat(64),
          ["self-hosted", "linux"],
          [protocol_repo],
        ),
      )
      let a = c.claim(provider_secret, claim_request()).unwrap()
      let b = c
        .claim("c".repeat(64), claim_request(id="2", secret="d".repeat(64)))
        .unwrap()
      ignore(
        complete_output_job(c, b, "d".repeat(64), {
          "shared": "second-instance-first",
        }),
      )
      let empty = c
        .claim("c".repeat(64), claim_request(id="3", secret="e".repeat(64)))
        .unwrap()
      ignore(
        complete_output_job(c, a, attempt_secret, {
          "shared": "first-instance-last",
        }),
      )
      assert_true(
        c.claim(provider_secret, claim_request(id="4", secret="f".repeat(64)))
        is None,
      )
      // Upstream runners omit empty values. The last finishing instance must
      // not erase a non-empty output from an earlier matrix completion.
      ignore(complete_output_job(c, empty, "e".repeat(64), { "shared": "" }))
      let after = c
        .claim(provider_secret, claim_request(id="5", secret="0".repeat(64)))
        .unwrap()
      assert_eq(
        after.job.needs.get("build"),
        Some(
          (
            {
              "result": "success",
              "outputs": { "shared": "first-instance-last" },
            } : Json),
        ),
      )
    },
    workflow~,
  )
}

///|
async test "invalid dynamic job conditions fail locally and root false conditions never claim" {
  let source = output_workflow
    .replace_all(
      old="needs.prepare.outputs.version == '1.2.3'",
      new="format(needs.prepare.outputs.version)",
    )
    .replace_all(
      old="if: needs.prepare.outputs.version == 'other'",
      new="if: false",
    )
  with_protocol_fixture(
    (c, pool, _, run, _, _) => {
      let a = c.claim(provider_secret, claim_request()).unwrap()
      ignore(complete_output_job(c, a, attempt_secret, { "version": "{" }))
      assert_true(
        c.claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        is None,
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
      assert_true(
        list_jobs(
          pool,
          @identity.active_user_by_name(pool, "alice"),
          protocol_repo,
          run.number,
        )
        .iter()
        .find_first(job => job.job_key == "build")
        .unwrap().conclusion
        is Some(Failure),
      )
    },
    workflow=source,
  )
  with_protocol_fixture(
    (c, _, _, run, _, _) => {
      assert_true(run.state is Completed)
      assert_true(c.claim(provider_secret, claim_request()) is None)
    },
    workflow=@test_support.single_job_workflow.replace_all(
      old="runs-on:",
      new="if: false\n    runs-on:",
    ),
  )
}

///|
async test "outputs from expired cancelled or previous run attempts cannot leak into a new run" {
  with_protocol_fixture(
    (c, pool, root, run, _, clock) => {
      let old = c.claim(provider_secret, claim_request()).unwrap()
      clock.val += @protocol.lease_ms + 1L
      ignore(c.expire_attempts())
      let restarted = rerun_run(
        pool,
        root,
        @identity.active_user_by_name(pool, "alice"),
        protocol_repo,
        run.number,
      )
      let fresh = c
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap()
      assert_eq(fresh.job.id, "prepare")
      try
        ignore(
          complete_output_job(c, old, attempt_secret, { "version": "stale" }),
        )
      catch {
        Conflict(_) => ()
        err => raise err
      } noraise {
        _ => fail("expired lease published output")
      }
      ignore(
        complete_output_job(c, fresh, "c".repeat(64), { "version": "1.2.3" }),
      )
      let build = c
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap()
      ignore(complete_output_job(c, build, "d".repeat(64), Map([])))
      let rerun = rerun_run(
        pool,
        root,
        @identity.active_user_by_name(pool, "alice"),
        protocol_repo,
        restarted.number,
      )
      let again = c
        .claim(provider_secret, claim_request(id="4", secret="e".repeat(64)))
        .unwrap()
      assert_eq(again.run_id, rerun.id.to_string())
      assert_true(again.job.needs.is_empty())
      assert_eq(again.job.id, "prepare")
      c.cancel_run(
        @identity.active_user_by_name(pool, "alice"),
        protocol_repo,
        rerun.number,
      )
      let id = @protocol.parse_decimal(again.attempt_id).unwrap()
      ignore(
        c.complete(id, "e".repeat(64), {
          ..completion(conclusion="cancelled"),
          outputs: { "version": "cancelled" },
        }),
      )
      assert_true(
        c.claim(provider_secret, claim_request(id="5", secret="f".repeat(64)))
        is None,
      )
      pool.with_client(client => {
        assert_eq(
          (
            client
            .query_one("SELECT COUNT(*) AS n FROM pipeline_job_output")
            .get_name("n") : Int64),
          1L,
        )
      })
    },
    workflow=output_workflow,
  )
}

///|
async test "undeclared oversized and NUL outputs are rejected without completing an attempt" {
  with_protocol_fixture(
    (c, pool, _, _, _, _) => {
      let a = c.claim(provider_secret, claim_request()).unwrap()
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      ignore(c.start(id, attempt_secret, 1, execution_id="1".repeat(32)))
      for
        values in [
          { "undeclared": "value" },
          { "version": "x".repeat(16385) },
          { "version": "\u{0000}" },
          { "version": "\"".repeat(16384) },
          {
            "version": "x".repeat(16380),
            "secret": "x".repeat(16380),
            "other": "",
          },
        ] {
        try
          ignore(
            c.complete(id, attempt_secret, {
              ..completion(conclusion="failure"),
              outputs: values,
            }),
          )
        catch {
          @domain.BadRequest(_) => ()
          err => raise err
        } noraise {
          _ => fail("invalid outputs accepted")
        }
      }
      pool.with_client(client => {
        assert_true(
          client.query_all("SELECT * FROM pipeline_job_output").is_empty(),
        )
      })
      ignore(c.complete(id, attempt_secret, completion(conclusion="failure")))
    },
    workflow=output_workflow,
  )
}

///|
async test "run output quota is enforced transactionally across matrix jobs" {
  let source = output_workflow.replace_all(
    old="  prepare:\n",
    new="  prepare:\n    strategy: {matrix: {i: [0,1,2,3,4,5,6,7,8]}}\n",
  )
  with_protocol_fixture(
    (c, pool, _, run, _, _) => {
      for index = 0; index < 9; index = index + 1 {
        let token = @identity.random_hex(32)
        let a = c
          .claim(provider_secret, {
            version: 1,
            runner_os: None,
            request_id: @identity.random_hex(16),
            attempt_token: token,
          })
          .unwrap()
        let id = @protocol.parse_decimal(a.attempt_id).unwrap()
        ignore(c.start(id, token, 1, execution_id="1".repeat(32)))
        let request = {
          ..completion(conclusion="failure"),
          outputs: { "version": "x".repeat(16300), "secret": "y".repeat(16300) },
        }
        if index < 8 {
          ignore(c.complete(id, token, request))
        } else {
          try ignore(c.complete(id, token, request)) catch {
            @domain.BadRequest(_) => ()
            err => raise err
          } noraise {
            _ => fail("run outputs exceeded quota")
          }
          ignore(c.complete(id, token, completion(conclusion="failure")))
        }
      }
      pool.with_client(client => {
        assert_eq(
          (
            client
            .query_one("SELECT COUNT(*) AS n FROM pipeline_job_output")
            .get_name("n") : Int64),
          8L,
        )
      })
      assert_true(
        get_run(
          pool,
          @identity.active_user_by_name(pool, "alice"),
          protocol_repo,
          run.number,
        ).state
        is Completed,
      )
    },
    workflow=source.replace_all(
      old="strategy: {matrix:",
      new="strategy: {fail-fast: false, matrix:",
    ),
  )
}

///|
async test "legacy definition 3 assignments keep their wire version empty dataflow and completion hash" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, actor, protocol_repo)
    let sha = @test_support.workflow_commit(
      protocol_repo.git_dir(root),
      dag_workflow,
    )
    pool.with_client(client => {
      client.with_transaction(tx => {
        ignore(
          insert_run_snapshot(
            tx,
            scope.id,
            actor.id,
            ".github/workflows/build.yml",
            "Legacy",
            "pipeline",
            sha,
            "refs/moonhub/pipelines/legacy-v3",
            dag_workflow,
            @workflow.parse(dag_workflow),
            definition_version=3,
          ),
        )
      })
    })
    let c = merge_check_provider(pool)
    for index = 0; index < 3; index = index + 1 {
      let token = @identity.random_hex(32)
      let a = c
        .claim(provider_secret, {
          version: 1,
          runner_os: None,
          request_id: @identity.random_hex(16),
          attempt_token: token,
        })
        .unwrap()
      assert_eq(a.version, @protocol.scheduling_assignment_version)
      assert_true(a.job.outputs.is_empty())
      assert_true(a.job.needs.is_empty())
      let request = complete_output_job(c, a, token, Map([]))
      let old_payload : Json = {
        "version": request.version,
        "conclusion": request.conclusion,
        "last_log_sequence": request.last_log_sequence,
      }
      pool.with_client(client => {
        assert_eq(
          (
            client
            .query_one(
              "SELECT result_hash FROM pipeline_job_attempt WHERE id=?",
              params=[@protocol.parse_decimal(a.attempt_id).unwrap()],
            )
            .get_name("result_hash") : String),
          @identity.hash_token(old_payload.stringify()),
        )
      })
      ignore(
        c.complete(
          @protocol.parse_decimal(a.attempt_id).unwrap(),
          token,
          request,
        ),
      )
    }
  })
}
