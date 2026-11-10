///|
let dispatch_workflow : String =
  #|name: Dispatch snapshot
  #|on:
  #|  workflow_dispatch:
  #|    inputs:
  #|      version: {required: true}
  #|      enabled: {type: boolean, default: false}
  #|      count: {type: number, default: .5}
  #|      channel: {type: choice, options: [stable, beta], default: stable}
  #|concurrency:
  #|  group: release-${{ inputs.channel }}-${{ github.ref }}
  #|  cancel-in-progress: inputs.enabled
  #|jobs:
  #|  prepare:
  #|    if: inputs.enabled && github.event.inputs.enabled == 'true'
  #|    runs-on: self-hosted
  #|    outputs:
  #|      version: ${{ inputs.version }}
  #|    steps: [{id: prepare, run: echo prepare}]
  #|  consume:
  #|    needs: prepare
  #|    if: inputs.count == 3.5 && needs.prepare.outputs.version == inputs.version
  #|    runs-on: self-hosted
  #|    steps: [{run: echo consume}]
  #|  skipped:
  #|    if: '!inputs.enabled'
  #|    runs-on: self-hosted
  #|    steps: [{run: exit 99}]

///|
async test "dispatch captures typed inputs for scheduler assignment and immutable reruns" {
  let inputs : Map[String, Json] = {
    "version": "1.2.3",
    "enabled": true,
    "count": 3.5,
  }
  with_protocol_fixture(
    (c, pool, root, run, _, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let captured = run.context.unwrap()
      assert_eq(captured.inputs.get("enabled"), Some(Json::boolean(true)))
      assert_eq(captured.inputs.get("count"), Some(Json::number(3.5)))
      assert_eq(captured.inputs.get("channel"), Some(Json::string("stable")))
      assert_eq(run.definition_version, 7)
      let group = pool.with_client(client => {
        client.query_one(
          "SELECT group_key FROM pipeline_run_schedule WHERE run_id=?",
          params=[run.id],
        )
      })
      assert_eq(
        (group.get_name("group_key") : String),
        "release-stable-refs/heads/pipeline",
      )
      let first = c.claim(provider_secret, claim_request()).unwrap()
      assert_eq(first.version, @protocol.variable_assignment_version)
      assert_eq(first.job.id, "prepare")
      assert_eq(
        ToJson::to_json(first.job.dispatch_inputs),
        ToJson::to_json(captured.inputs),
      )
      assert_eq(
        first.job.event.get("inputs"),
        Some(
          (
            {
              "version": "1.2.3",
              "enabled": "true",
              "count": "3.5",
              "channel": "stable",
            } : Json),
        ),
      )
      assert_eq(
        first.job.event.get("ref"),
        Some(Json::string("refs/heads/pipeline")),
      )
      ignore(
        @test_support.workflow_commit(
          protocol_repo.git_dir(root),
          @test_support.single_job_workflow,
        ),
      )
      ignore(
        complete_output_job(c, first, attempt_secret, { "version": "1.2.3" }),
      )
      let token = "c".repeat(64)
      let second = c
        .claim(provider_secret, claim_request(id="2", secret=token))
        .unwrap()
      assert_eq(second.job.id, "consume")
      assert_eq(
        ToJson::to_json(second.job.dispatch_inputs),
        ToJson::to_json(captured.inputs),
      )
      ignore(complete_output_job(c, second, token, Map([])))
      assert_true(
        get_run(pool, actor, protocol_repo, run.number).conclusion
        is Some(Success),
      )
      let again = rerun_run(pool, root, actor, protocol_repo, run.number)
      assert_eq(
        ToJson::to_json(again.context.unwrap()),
        ToJson::to_json(captured),
      )
      assert_eq(again.commit_sha, run.commit_sha)
      assert_eq(again.workflow_source, dispatch_workflow)
      let repeated = c
        .claim(provider_secret, claim_request(id="3", secret="d".repeat(64)))
        .unwrap()
      assert_eq(
        ToJson::to_json(repeated.job.dispatch_inputs),
        ToJson::to_json(captured.inputs),
      )
      assert_eq(
        ToJson::to_json(repeated.job.event),
        ToJson::to_json(first.job.event),
      )
    },
    workflow=dispatch_workflow,
    inputs~,
  )
}

///|
async test "invalid dispatch inputs leave no run or source pin" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let dir = protocol_repo.git_dir(root)
    ignore(@test_support.workflow_commit(dir, dispatch_workflow))
    for
      inputs in [
        ({} : Map[String, Json]),
        { "version": "1", "unknown": true },
        { "version": "1", "count": "NaN" },
        { "version": "x".repeat(65536) },
      ] {
      try
        ignore(
          create_run(
            pool,
            root,
            actor,
            protocol_repo,
            "pipeline",
            ".github/workflows/build.yml",
            inputs~,
          ),
        )
      catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("invalid dispatch accepted")
      }
      assert_true(list_runs(pool, actor, protocol_repo).is_empty())
      assert_eq(
        @gitops.merge_git(dir, [
          "for-each-ref", "--format=%(refname)", "refs/moonhub/pipelines/",
        ])
        .trim()
        .to_owned(),
        "",
      )
    }
  })
}

///|
test "legacy run context defaults omitted dispatch inputs" {
  let context : @workflow.RunContext = @json.from_json(
    @json.parse(
      (
        #|{"repository":"alice/demo","sha":"abc","event_name":"push","head_ref":"","base_ref":""}
      ),
    ),
  )
  assert_true(context.inputs.is_empty())
}

///|
async test "version four snapshots and reruns retain the version seven wire contract" {
  let workflow =
    #|on: workflow_dispatch
    #|concurrency: legacy-${{ github.event.ref }}-${{ !github.event }}
    #|jobs:
    #|  build:
    #|    if: github.event.ref == '' && !github.event
    #|    runs-on: self-hosted
    #|    steps: [{if: '!github.event', run: echo legacy}]
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, actor, protocol_repo)
    let dir = protocol_repo.git_dir(root)
    let sha = @test_support.workflow_commit(dir, workflow)
    let pin = "refs/moonhub/pipelines/legacy-v4"
    ignore(@gitops.merge_git(dir, ["update-ref", pin, sha]))
    let run = pool.with_client(client => {
      client.with_transaction(tx => {
        insert_run_snapshot(
          tx,
          scope.id,
          actor.id,
          ".github/workflows/build.yml",
          "Legacy dataflow",
          "pipeline",
          sha,
          pin,
          workflow,
          @workflow.parse(workflow),
          definition_version=4,
          context=Some({
            repository: "alice/demo",
            sha,
            event_name: "workflow_dispatch",
            head_ref: "",
            base_ref: "",
            inputs: Map([]),
            variables: Map([]),
          }),
        )
      })
    })
    let scheduled = pool.with_client(client => {
      client.query_one(
        "SELECT group_key FROM pipeline_run_schedule WHERE run_id=?",
        params=[run.id],
      )
    })
    assert_eq((scheduled.get_name("group_key") : String), "legacy--true")
    let c = merge_check_provider(pool)
    let (a, token) = claim_dag_attempt(c, provider_secret)
    assert_eq(a.version, @protocol.dataflow_assignment_version)
    assert_true(a.job.dispatch_inputs.is_empty())
    assert_true(a.job.event.is_empty())
    ignore(complete_output_job(c, a, token, Map([])))
    let again = rerun_run(pool, root, actor, protocol_repo, run.number)
    assert_eq(again.definition_version, 4)
    assert_true(again.context is Some(_))
    let (a, _) = claim_dag_attempt(c, provider_secret)
    assert_eq(a.version, @protocol.dataflow_assignment_version)
    assert_true(a.job.dispatch_inputs.is_empty())
    assert_true(a.job.event.is_empty())
  })
}

///|
async test "MR scheduler and runner agree on captured event reference with empty dispatch inputs" {
  let workflow =
    #|on: pull_request
    #|concurrency: ${{ github.event.ref }}
    #|jobs:
    #|  check:
    #|    if: github.event.ref == github.ref
    #|    runs-on: self-hosted
    #|    steps: [{run: echo event}]
  with_merge_check_fixture(
    (pool, root, _, actor, _) => {
      poll_merge_checks(pool, root)
      let run = list_runs(pool, actor, protocol_repo)[0]
      assert_true(run.context.unwrap().inputs.is_empty())
      let c = merge_check_provider(pool)
      let (assignment, _) = claim_dag_attempt(c, provider_secret)
      assert_true(assignment.job.dispatch_inputs.is_empty())
      let event_ref = assignment.job.context["ref"]
      assert_true(event_ref.has_prefix("refs/pull/"))
      assert_eq(assignment.job.event.get("ref"), Some(Json::string(event_ref)))
      assert_true(assignment.job.event.get("inputs") is None)
      let scheduled = pool.with_client(client => {
        client.query_one(
          "SELECT group_key FROM pipeline_run_schedule WHERE run_id=?",
          params=[run.id],
        )
      })
      assert_eq((scheduled.get_name("group_key") : String), event_ref)
    },
    workflow~,
    required=false,
  )
}
