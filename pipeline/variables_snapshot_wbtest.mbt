///|
let variables_workflow : String =
  #|name: Repository configuration
  #|on: [workflow_dispatch, push, pull_request]
  #|concurrency:
  #|  group: release-${{ vars.OPENSEEK_S3_REGION }}-${{ github.ref }}
  #|  cancel-in-progress: vars.CANCEL == 'yes'
  #|jobs:
  #|  prepare:
  #|    if: vars.enabled == 'yes' && vars.NOT_CONFIGURED == ''
  #|    runs-on: self-hosted
  #|    outputs:
  #|      region: ${{ vars.OPENSEEK_S3_REGION }}
  #|    steps:
  #|      - env:
  #|          REGION: ${{ vars.OPENSEEK_S3_REGION }}
  #|          LITERAL: ${{ vars.LITERAL }}
  #|        run: echo prepare
  #|  consume:
  #|    needs: prepare
  #|    if: needs.prepare.outputs.region == vars.OPENSEEK_S3_REGION
  #|    runs-on: self-hosted
  #|    steps: [{run: echo consume}]
  #|  skipped:
  #|    if: vars.ENABLED == 'no'
  #|    runs-on: self-hosted
  #|    steps: [{run: exit 99}]

///|
async test "repository variables snapshot atomically and survive edits deletion ref drift and reruns" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo = protocol_repo
    let dir = repo.git_dir(root)
    save_variable(pool, actor, repo, "openseek_s3_region", "ap-southeast-1", 0L)
    save_variable(pool, actor, repo, "ENABLED", "yes", 0L)
    save_variable(
      pool, actor, repo, "LITERAL", "${{ secrets.NOT_A_SECRET }}", 0L,
    )
    let sha = @test_support.workflow_commit(dir, variables_workflow)
    let run = create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    let captured = run.context.unwrap().variables
    assert_eq(run.definition_version, 6)
    assert_eq(captured.get("OPENSEEK_S3_REGION"), Some("ap-southeast-1"))
    assert_eq(captured.get("ENABLED"), Some("yes"))
    assert_eq(captured.get("LITERAL"), Some("${{ secrets.NOT_A_SECRET }}"))
    let scheduled = pool.with_client(client => {
      client.query_one(
        "SELECT group_key FROM pipeline_run_schedule WHERE run_id=?",
        params=[run.id],
      )
    })
    assert_eq(
      (scheduled.get_name("group_key") : String),
      "release-ap-southeast-1-refs/heads/pipeline",
    )
    for variable in list_variables(pool, actor, repo) {
      if variable.name == "OPENSEEK_S3_REGION" {
        save_variable(
          pool,
          actor,
          repo,
          variable.name,
          "eu-west-1",
          variable.version,
        )
      } else {
        delete_variable(pool, actor, repo, variable.name, variable.version)
      }
    }
    ignore(
      @test_support.workflow_commit(dir, @test_support.single_job_workflow),
    )
    let c = merge_check_provider(pool)
    let (first, token) = claim_dag_attempt(c, provider_secret)
    assert_eq(first.version, @protocol.variable_assignment_version)
    assert_eq(first.job.id, "prepare")
    assert_eq(ToJson::to_json(first.job.variables), ToJson::to_json(captured))
    assert_true(first.job.steps[0].env.get("OPENSEEK_S3_REGION") is None)
    assert_eq(
      first.job.steps[0].templates.get("env:REGION"),
      Some("${{ vars.OPENSEEK_S3_REGION }}"),
    )
    ignore(complete_output_job(c, first, token, { "region": "ap-southeast-1" }))
    let (second, token) = claim_dag_attempt(c, provider_secret)
    assert_eq(second.job.id, "consume")
    assert_eq(ToJson::to_json(second.job.variables), ToJson::to_json(captured))
    ignore(complete_output_job(c, second, token, Map([])))
    let completed = get_run(pool, actor, repo, run.number)
    assert_true(completed.conclusion is Some(Success))
    let again = rerun_run(pool, root, actor, repo, run.number)
    assert_eq(again.commit_sha, sha)
    assert_eq(
      ToJson::to_json(again.context.unwrap().variables),
      ToJson::to_json(captured),
    )
    let (assignment, _) = claim_dag_attempt(c, provider_secret)
    assert_eq(assignment.job.id, "prepare")
    assert_eq(
      ToJson::to_json(assignment.job.variables),
      ToJson::to_json(captured),
    )
  })
}

///|
async test "legacy definition five reruns do not capture newly configured repository variables" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, actor, protocol_repo)
    let dir = protocol_repo.git_dir(root)
    let source = @test_support.single_job_workflow
    let sha = @test_support.workflow_commit(dir, source)
    let pin = "refs/moonhub/pipelines/legacy-v5-variables"
    ignore(@gitops.merge_git(dir, ["update-ref", pin, sha]))
    let legacy_context : @workflow.RunContext = @json.from_json(
      @json.parse(
        "{\"repository\":\"alice/demo\",\"sha\":\"" +
        sha +
        "\",\"event_name\":\"workflow_dispatch\",\"head_ref\":\"\",\"base_ref\":\"\",\"inputs\":{}}",
      ),
    )
    assert_true(legacy_context.variables.is_empty())
    let run = pool.with_client(client => {
      client.with_transaction(tx => {
        insert_run_snapshot(
          tx,
          scope.id,
          actor.id,
          ".github/workflows/build.yml",
          "Legacy dispatch",
          "pipeline",
          sha,
          pin,
          source,
          @workflow.parse(source),
          definition_version=5,
          context=Some(legacy_context),
        )
      })
    })
    save_variable(pool, actor, protocol_repo, "NOW_AVAILABLE", "new", 0L)
    let c = merge_check_provider(pool)
    let (a, token) = claim_dag_attempt(c, provider_secret)
    assert_eq(a.version, @protocol.dispatch_assignment_version)
    assert_true(a.job.variables.is_empty())
    ignore(complete_output_job(c, a, token, Map([])))
    let again = rerun_run(pool, root, actor, protocol_repo, run.number)
    assert_eq(again.definition_version, 5)
    assert_true(again.context.unwrap().variables.is_empty())
    let (a, _) = claim_dag_attempt(c, provider_secret)
    assert_eq(a.version, @protocol.dispatch_assignment_version)
    assert_true(a.job.variables.is_empty())
  })
}

///|
async test "authorized MR checks capture public repository variables" {
  with_merge_check_fixture(
    (pool, root, _, actor, _) => {
      save_variable(
        pool, actor, protocol_repo, "OPENSEEK_S3_REGION", "mr-region", 0L,
      )
      save_variable(pool, actor, protocol_repo, "ENABLED", "yes", 0L)
      poll_merge_checks(pool, root)
      let run = list_runs(pool, actor, protocol_repo)[0]
      assert_eq(
        run.context.unwrap().variables.get("OPENSEEK_S3_REGION"),
        Some("mr-region"),
      )
      let c = merge_check_provider(pool)
      let (a, _) = claim_dag_attempt(c, provider_secret)
      assert_eq(a.version, @protocol.variable_assignment_version)
      assert_eq(a.job.variables.get("ENABLED"), Some("yes"))
      assert_true(a.job.dispatch_inputs.is_empty())
      assert_true(a.job.event.get("inputs") is None)
    },
    workflow=variables_workflow,
    required=false,
  )
}
