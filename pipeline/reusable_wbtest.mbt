///|
let call_workflow : String =
  #|on: workflow_dispatch
  #|permissions: {contents: read}
  #|jobs:
  #|  call:
  #|    uses: ./.github/workflows/callee.yml
  #|    with: {enabled: true, label: pinned}
  #|  after:
  #|    needs: call
  #|    runs-on: self-hosted
  #|    steps: [{run: 'echo ${{ needs.call.outputs.version }}'}]

///|
let called_workflow : String =
  #|on:
  #|  workflow_call:
  #|    inputs:
  #|      enabled: {type: boolean, required: true}
  #|      label: {type: string, default: none}
  #|    outputs:
  #|      version: {value: '${{ jobs.build.outputs.version }}'}
  #|permissions: {contents: write, id-token: write}
  #|jobs:
  #|  build:
  #|    if: inputs.enabled
  #|    runs-on: self-hosted
  #|    outputs: {version: '${{ steps.build.outputs.version }}'}
  #|    steps:
  #|      - id: build
  #|        run: echo original
  #|        env: {SHA: '${{ github.sha }}'}

///|
async fn with_reusable_fixture(
  f : async (
    PipelineFixture,
    @database.Database,
    String,
    @runtime.Run,
    Ref[Int64],
  ) -> Unit,
  caller~ : String = call_workflow,
  callee~ : String = called_workflow,
  files~ : Array[(String, String)] = [],
  secret~ : Bool = false,
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let clock = Ref(1700000000000L)
    let c = test_services(pool, clock=() => clock.val)
    ignore(
      c.runtime.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "default",
        provider_secret,
        ["self-hosted", "linux"],
        [protocol_repo],
      ),
    )
    let dir = protocol_repo.git_dir(root)
    let sources = [
      (".github/workflows/build.yml", caller),
      (".github/workflows/callee.yml", callee),
    ]
    sources.append(files)
    ignore(
      filter_test_commit(
        dir,
        @gitops.branch_sha(dir, "master"),
        "pipeline",
        sources,
      ),
    )
    if secret {
      let actor = @identity.active_user_by_name(pool, "alice")
      @runtime.save_secret(
        pool,
        root,
        actor,
        @runtime.require_run_author(pool, actor, protocol_repo),
        "TOKEN",
        Some("private-token-value"),
        "pipeline",
        ".github/workflows/build.yml",
        0L,
      )
    }
    let run = create_run(
      pool,
      root,
      @identity.active_user_by_name(pool, "alice"),
      protocol_repo,
      "pipeline",
      ".github/workflows/build.yml",
    )
    f(c, pool, root, run, clock)
  })
}

///|
async test "reusable callee inputs permissions outputs and source survive branch movement and reruns" {
  with_reusable_fixture((c, pool, root, run, clock) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let dir = protocol_repo.git_dir(root)
    ignore(
      filter_test_commit(dir, run.commit_sha, "pipeline", [
        (".github/workflows/build.yml", call_workflow),
        (
          ".github/workflows/callee.yml",
          called_workflow.replace_all(old="echo original", new="echo changed"),
        ),
      ]),
    )
    let restarted = test_services(pool, clock=() => clock.val)
    let child = restarted.runtime
      .claim(provider_secret, claim_request())
      .unwrap()
    assert_eq(child.job.id, "build")
    assert_true(child.job.dispatch_inputs.get("enabled") is Some(True))
    assert_eq(
      child.job.dispatch_inputs.get("label"),
      Some(Json::string("pinned")),
    )
    assert_eq(child.job.steps[0].run, "echo original")
    assert_eq(child.job.steps[0].env.get("SHA"), Some(run.commit_sha))
    assert_eq(child.job.api_permissions, 1)
    assert_false(child.job.id_token_write)
    let request = complete_output_job(restarted, child, attempt_secret, {
      "version": "1.2.3",
    })
    ignore(
      restarted.runtime.complete(
        @protocol.parse_decimal(child.attempt_id).unwrap(),
        attempt_secret,
        request,
      ),
    )
    let after = restarted.runtime
      .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
      .unwrap()
    assert_eq(after.job.id, "after")
    assert_true(
      after.job.needs.get("call")
      is Some(
        { "result": "success", "outputs": { "version": "1.2.3", .. }, .. },
      ),
    )
    ignore(
      complete_output_job(
        restarted,
        after,
        "c".repeat(64),
        Map([]),
        conclusion="failure",
      ),
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
      @runtime.list_jobs(pool, actor, protocol_repo, again.number)[0].reused_from,
      Some(run.number),
    )
    let retry = c.runtime
      .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
      .unwrap()
    assert_eq(retry.job.id, "after")
    assert_true(
      retry.job.needs.get("call")
      is Some({ "outputs": { "version": "1.2.3", .. }, .. }),
    )
    ignore(complete_output_job(c, retry, "d".repeat(64), Map([])))
    let full = rerun_run(pool, root, actor, protocol_repo, run.number)
    assert_eq(full.commit_sha, run.commit_sha)
    let child = c.runtime
      .claim(provider_secret, claim_request(id="4", secret="e".repeat(64)))
      .unwrap()
    assert_eq(child.job.steps[0].run, "echo original")
  })
}

///|
async test "callee failure fails its caller aggregate and skips ordinary dependents" {
  with_reusable_fixture((c, pool, _, run, _) => {
    let child = c.runtime.claim(provider_secret, claim_request()).unwrap()
    ignore(
      complete_output_job(
        c,
        child,
        attempt_secret,
        Map([]),
        conclusion="failure",
      ),
    )
    let actor = @identity.active_user_by_name(pool, "alice")
    let jobs = @runtime.list_jobs(pool, actor, protocol_repo, run.number)
    assert_true(jobs[0].conclusion is Some(Failure))
    assert_true(jobs[1].conclusion is Some(Skipped))
    assert_true(
      @runtime.get_run(pool, actor, protocol_repo, run.number).conclusion
      is Some(Failure),
    )
  })
}

///|
async test "failed-only reusable reruns preserve inputs shared by reused and retried children" {
  let caller = call_workflow.replace_all(
    old="label: pinned",
    new="label: 'attempt-${{ github.run_attempt }}'",
  )
  let callee = "concurrency: '${{ inputs.label }}'\n" +
    called_workflow +
    "\n  verify:\n    runs-on: self-hosted\n    steps: [{run: echo verify}]\n"
  with_reusable_fixture(
    (c, pool, root, run, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let child = c.runtime.claim(provider_secret, claim_request()).unwrap()
      assert_eq(child.job.id, "build")
      assert_eq(
        child.job.dispatch_inputs.get("label"),
        Some(Json::string("attempt-1")),
      )
      ignore(complete_output_job(c, child, attempt_secret, Map([])))
      let verify = c.runtime
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap()
      assert_eq(verify.job.id, "verify")
      ignore(
        complete_output_job(
          c,
          verify,
          "c".repeat(64),
          Map([]),
          conclusion="failure",
        ),
      )
      let again = rerun_run(
        pool,
        root,
        actor,
        protocol_repo,
        run.number,
        failed_only=true,
      )
      let jobs = @runtime.list_jobs(pool, actor, protocol_repo, again.number)
      assert_eq(
        jobs.iter().find_first(job => job.job_key == "call/build").unwrap().reused_from,
        Some(run.number),
      )
      pool.with_client(client => {
        let key : String = client
          .query_one(
            "SELECT group_key FROM pipeline_concurrency_slot WHERE run_id=?",
            params=[again.id],
          )
          .get_name("group_key")
        assert_eq(key, "attempt-1")
      })
      let retry = c.runtime
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap()
      assert_eq(retry.job.id, "verify")
      assert_eq(
        retry.job.dispatch_inputs.get("label"),
        Some(Json::string("attempt-1")),
      )
      ignore(complete_output_job(c, retry, "d".repeat(64), Map([])))
      let after = c.runtime
        .claim(provider_secret, claim_request(id="4", secret="e".repeat(64)))
        .unwrap()
      ignore(complete_output_job(c, after, "e".repeat(64), Map([])))
      ignore(rerun_run(pool, root, actor, protocol_repo, run.number))
      let fresh = c.runtime
        .claim(provider_secret, claim_request(id="5", secret="f".repeat(64)))
        .unwrap()
      assert_eq(
        fresh.job.dispatch_inputs.get("label"),
        Some(Json::string("attempt-3")),
      )
    },
    caller~,
    callee~,
  )
}

///|
async test "reusable concurrency holds cancellation until callee execution is fenced" {
  let caller = call_workflow.replace_all(
    old="    uses:",
    new="    concurrency: {group: called-deploy, cancel-in-progress: true}\n    uses:",
  )
  with_reusable_fixture(
    (c, pool, root, run, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let child = c.runtime.claim(provider_secret, claim_request()).unwrap()
      let id = @protocol.parse_decimal(child.attempt_id).unwrap()
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
      assert_true(
        @runtime.get_run(pool, actor, protocol_repo, run.number).conclusion
        is Some(Cancelled),
      )
      let next_child = c.runtime
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap()
      assert_eq(next_child.run_id, next.id.to_string())
      assert_eq(next_child.job.id, "build")
    },
    caller~,
  )
}

///|
async test "dependency output inputs and dynamic callee matrices retain their local context" {
  let caller =
    #|on: workflow_dispatch
    #|jobs:
    #|  prepare:
    #|    runs-on: self-hosted
    #|    outputs: {matrix: '${{ steps.plan.outputs.matrix }}'}
    #|    steps: [{id: plan, run: echo prepare}]
    #|  call:
    #|    needs: prepare
    #|    uses: ./.github/workflows/callee.yml
    #|    with: {matrix: '${{ needs.prepare.outputs.matrix }}'}
    #|  after:
    #|    needs: call
    #|    runs-on: self-hosted
    #|    steps: [{run: echo done}]
  let callee =
    #|on:
    #|  workflow_call:
    #|    inputs: {matrix: {type: string, required: true}}
    #|    outputs: {target: {value: '${{ jobs.build.outputs.target }}'}}
    #|jobs:
    #|  build:
    #|    runs-on: self-hosted
    #|    strategy: {matrix: '${{ fromJSON(inputs.matrix) }}'}
    #|    outputs: {target: '${{ matrix.target }}'}
    #|    steps: [{run: 'echo ${{ matrix.target }}'}]
  with_reusable_fixture(
    (c, pool, _, run, _) => {
      let prepare = c.runtime.claim(provider_secret, claim_request()).unwrap()
      ignore(
        complete_output_job(c, prepare, attempt_secret, {
          "matrix": "{\"target\":[\"one\",\"two\"]}",
        }),
      )
      for index in 0..<2 {
        let token = if index == 0 { "c".repeat(64) } else { "d".repeat(64) }
        let child = c.runtime
          .claim(
            provider_secret,
            claim_request(id=(index + 2).to_string(), secret=token),
          )
          .unwrap()
        assert_eq(child.job.id, "build")
        assert_eq(
          child.job.matrix.get("target"),
          Some(Json::string(if index == 0 { "one" } else { "two" })),
        )
        ignore(
          complete_output_job(c, child, token, {
            "target": if index == 0 {
              "one"
            } else {
              "two"
            },
          }),
        )
      }
      let after = c.runtime
        .claim(provider_secret, claim_request(id="4", secret="e".repeat(64)))
        .unwrap()
      assert_true(
        after.job.needs.get("call")
        is Some({ "outputs": { "target": "two", .. }, .. }),
      )
      ignore(complete_output_job(c, after, "e".repeat(64), Map([])))
      assert_true(
        @runtime.get_run(
          pool,
          @identity.active_user_by_name(pool, "alice"),
          protocol_repo,
          run.number,
        ).conclusion
        is Some(Success),
      )
    },
    caller~,
    callee~,
  )
}

///|
async test "nested reusable inputs outputs and permissions remain scoped to each call" {
  let callee =
    #|on:
    #|  workflow_call:
    #|    inputs:
    #|      enabled: {type: boolean, required: true}
    #|      label: {type: string, default: inner}
    #|    outputs: {version: {value: '${{ jobs.nested.outputs.version }}'}}
    #|permissions: {contents: write, id-token: write}
    #|jobs:
    #|  nested:
    #|    uses: ./.github/workflows/leaf.yml
    #|    with:
    #|      enabled: ${{ inputs.enabled }}
    #|      label: ${{ inputs.label }}
  with_reusable_fixture(
    (c, pool, _, run, _) => {
      let child = c.runtime.claim(provider_secret, claim_request()).unwrap()
      assert_eq(
        child.job.dispatch_inputs.get("label"),
        Some(Json::string("pinned")),
      )
      assert_eq(child.job.api_permissions, 1)
      assert_false(child.job.id_token_write)
      ignore(
        complete_output_job(c, child, attempt_secret, { "version": "nested" }),
      )
      let after = c.runtime
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap()
      assert_true(
        after.job.needs.get("call")
        is Some({ "outputs": { "version": "nested", .. }, .. }),
      )
      ignore(complete_output_job(c, after, "c".repeat(64), Map([])))
      let jobs = @runtime.list_jobs(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        protocol_repo,
        run.number,
      )
      assert_true(jobs.any(job => job.job_key == "call/nested/build"))
      assert_true(jobs.all(job => job.conclusion is Some(Success)))
    },
    callee~,
    files=[(".github/workflows/leaf.yml", called_workflow)],
  )
}

///|
async test "callee concurrency resolves typed callee inputs and run cancellation retains fencing" {
  let callee = "concurrency: '${{ inputs.label }}'\n" + called_workflow
  with_reusable_fixture(
    (c, pool, _, run, _) => {
      pool.with_client(client => {
        assert_eq(
          (
            client
            .query_one(
              "SELECT group_key FROM pipeline_concurrency_slot WHERE run_id=?",
              params=[run.id],
            )
            .get_name("group_key") : String),
          "pinned",
        )
      })
      let actor = @identity.active_user_by_name(pool, "alice")
      let child = c.runtime.claim(provider_secret, claim_request()).unwrap()
      let id = @protocol.parse_decimal(child.attempt_id).unwrap()
      ignore(c.runtime.start(id, attempt_secret, 1))
      c.runtime.cancel_run(actor, protocol_repo, run.number)
      assert_true(
        @runtime.list_jobs(pool, actor, protocol_repo, run.number)[0].state
        is Waiting,
      )
      assert_true(c.runtime.heartbeat(id, attempt_secret, 1).cancel_requested)
      ignore(
        c.runtime.complete(
          id,
          attempt_secret,
          completion(conclusion="cancelled"),
        ),
      )
      assert_true(
        @runtime.get_run(pool, actor, protocol_repo, run.number).conclusion
        is Some(Cancelled),
      )
    },
    callee~,
  )
}

///|
async test "callee jobs cannot wait on their own reusable call concurrency group" {
  let callee = "concurrency: called-deploy\n" +
    called_workflow.replace_all(
      old="    runs-on:",
      new="    concurrency: called-deploy\n    runs-on:",
    )
  with_reusable_fixture(
    (_, pool, _, run, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let jobs = @runtime.list_jobs(pool, actor, protocol_repo, run.number)
      let child = jobs
        .iter()
        .find_first(job => job.job_key == "call/build")
        .unwrap()
      assert_true(child.conclusion is Some(Failure))
      assert_eq(
        child.scheduling_error,
        "job concurrency group conflicts with its reusable caller group",
      )
      assert_true(
        @runtime.get_run(pool, actor, protocol_repo, run.number).conclusion
        is Some(Failure),
      )
    },
    callee~,
  )
}

///|
async test "callee job concurrency rejects a cycle between admitted reusable calls" {
  let caller =
    #|on: workflow_dispatch
    #|jobs:
    #|  first:
    #|    concurrency: first-call
    #|    uses: ./.github/workflows/callee.yml
    #|  second:
    #|    concurrency: second-call
    #|    uses: ./.github/workflows/other.yml
  let callee =
    #|on: workflow_call
    #|jobs:
    #|  prepare:
    #|    runs-on: self-hosted
    #|    steps: [{run: echo prepare}]
    #|  finalize:
    #|    needs: prepare
    #|    runs-on: self-hosted
    #|    concurrency: second-call
    #|    steps: [{run: echo finalize}]
  let other =
    #|on: workflow_call
    #|jobs:
    #|  build:
    #|    runs-on: self-hosted
    #|    concurrency: first-call
    #|    steps: [{run: echo build}]
  with_reusable_fixture(
    (c, pool, _, run, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let prepare = c.runtime.claim(provider_secret, claim_request()).unwrap()
      assert_eq(prepare.job.id, "prepare")
      assert_true(
        c.runtime.queue_reasons(actor, protocol_repo, run.number)["second/build"]
        is @runtime.WaitingConcurrency,
      )
      ignore(complete_output_job(c, prepare, attempt_secret, Map([])))
      let jobs = @runtime.list_jobs(pool, actor, protocol_repo, run.number)
      let finalize = jobs
        .iter()
        .find_first(job => job.job_key == "first/finalize")
        .unwrap()
      assert_true(finalize.conclusion is Some(Failure))
      assert_eq(
        finalize.scheduling_error,
        "job concurrency would deadlock admitted workflows or reusable calls",
      )
      let build = c.runtime
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap()
      assert_eq(build.job.id, "build")
    },
    caller~,
    callee~,
    files=[(".github/workflows/other.yml", other)],
  )
}

///|
async test "reusable aggregate outputs suppress reconstructed delivered secrets" {
  let callee = called_workflow
    .replace_all(
      old="'${{ jobs.build.outputs.version }}'",
      new="\"${{ format('{0}{1}', jobs.build.outputs.first, jobs.build.outputs.second) }}\"",
    )
    .replace_all(
      old="outputs: {version: '${{ steps.build.outputs.version }}'}",
      new="outputs: {first: '${{ steps.build.outputs.first }}', second: '${{ steps.build.outputs.second }}'}",
    )
    .replace_all(
      old="env: {SHA: '${{ github.sha }}'}",
      new="env: {TOKEN: '${{ secrets.TOKEN }}'}",
    )
  with_reusable_fixture(
    (c, _, _, _, _) => {
      let child = c.runtime.claim(provider_secret, claim_request()).unwrap()
      let id = @protocol.parse_decimal(child.attempt_id).unwrap()
      ignore(
        c.runtime.start(id, attempt_secret, 1, execution_id="1".repeat(32)),
      )
      ignore(
        c.runtime.update_step(id, attempt_secret, {
          version: 1,
          step_id: "build",
          state: "running",
          exit_code: 0,
        }),
      )
      ignore(
        c.runtime.step_secrets(id, attempt_secret, {
          version: 1,
          step_id: "build",
          execution_id: "1".repeat(32),
        }),
      )
      ignore(
        c.runtime.update_step(id, attempt_secret, {
          version: 1,
          step_id: "build",
          state: "success",
          exit_code: 0,
        }),
      )
      ignore(
        c.runtime.complete(id, attempt_secret, {
          ..completion(),
          outputs: { "first": "private-", "second": "token-value" },
        }),
      )
      let after = c.runtime
        .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
        .unwrap()
      assert_true(
        after.job.needs.get("call") is Some({ "outputs": Object(outputs), .. }) &&
        outputs.is_empty(),
        msg=ToJson::to_json(after.job.needs).stringify(),
      )
    },
    callee~,
    secret=true,
  )
}
