///|
async test "scheduled snapshots are opt in use UTC default branch and deduplicate a minute" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let source =
      #|name: Release
      #|run-name: "Release ${{ github.event_name == 'schedule' && 'daily' || inputs.version }} by @${{ github.actor }}"
      #|on:
      #|  schedule:
      #|    - cron: '0 6 * * *'
      #|  workflow_dispatch:
      #|    inputs:
      #|      version: {type: string, required: true}
      #|permissions: {contents: write, actions: read}
      #|jobs:
      #|  publish:
      #|    runs-on: [self-hosted, linux]
      #|    steps:
      #|      - run: echo release
    let sha = @test_support.workflow_commit(protocol_repo.git_dir(root), source)
    pool.with_client(c => {
      ignore(
        c.execute("UPDATE repository SET default_branch='pipeline' WHERE id=1"),
      )
    })
    let when = 1794463200000L
    run_due_schedules(pool, root, now_ms=when)
    assert_true(list_runs(pool, actor, protocol_repo).is_empty())
    set_scheduled_runs(pool, actor, protocol_repo, true)
    run_due_schedules(pool, root, now_ms=when)
    run_due_schedules(pool, root, now_ms=when)
    let runs = list_runs(pool, actor, protocol_repo)
    assert_eq(runs.length(), 1)
    assert_eq(runs[0].commit_sha, sha)
    assert_eq(runs[0].context.unwrap().event_name, "schedule")
    assert_eq(runs[0].display_title, "Release daily by @alice")
    pool.with_client(c => {
      ignore(c.execute("UPDATE pipeline_schedule_config SET polled_minute=-1"))
    })
    run_due_schedules(pool, root, now_ms=when)
    assert_eq(list_runs(pool, actor, protocol_repo).length(), 1)
    let manual = create_run(
      pool,
      root,
      actor,
      protocol_repo,
      "pipeline",
      ".github/workflows/build.yml",
      inputs={ "version": "1.2.3" },
    )
    assert_eq(manual.display_title, "Release 1.2.3 by @alice")
    set_scheduled_runs(pool, actor, protocol_repo, false)
    run_due_schedules(pool, root, now_ms=when + 86400000L)
    assert_eq(list_runs(pool, actor, protocol_repo).length(), 2)
  })
}

///|
async test "job API grants are repository permission event and live attempt bound" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let source =
      #|on: workflow_dispatch
      #|permissions: {contents: write, actions: read}
      #|jobs:
      #|  publish:
      #|    runs-on: [self-hosted, linux]
      #|    steps:
      #|      - run: echo release
    ignore(@test_support.workflow_commit(protocol_repo.git_dir(root), source))
    let run = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    let c = Coordinator::new(pool)
    ignore(
      c.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "release",
        provider_secret,
        ["self-hosted", "linux"],
        [protocol_repo],
      ),
    )
    let claimed = c.claim(provider_secret, claim_request()).unwrap()
    assert_eq(claimed.version, @protocol.release_assignment_version)
    let id = @protocol.parse_decimal(claimed.attempt_id).unwrap()
    ignore(c.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
    let grant = c.api_runtime(id, attempt_secret, {
      version: 1,
      execution_id: "e".repeat(32),
    })
    assert_eq(
      c.authenticate_job_api(grant.token, protocol_repo, "contents:write").id,
      actor.id,
    )
    assert_eq(
      c.authenticate_job_api(grant.token, protocol_repo, "actions:read").id,
      actor.id,
    )
    try
      ignore(
        c.authenticate_job_api(
          grant.token,
          { owner: "other", name: "repo", },
          "contents:write",
        ),
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("cross repository job token accepted")
    }
    c.cancel_run(actor, protocol_repo, run.number)
    try
      ignore(
        c.authenticate_job_api(grant.token, protocol_repo, "contents:write"),
      )
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("cancelled job retained release write")
    }
  })
}

///|
async test "explicit contents read grants release reads without publication or legacy scope expansion" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let source = "permissions: {contents: read}\n" + sample_workflow
    ignore(@test_support.workflow_commit(protocol_repo.git_dir(root), source))
    ignore(
      create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      ),
    )
    let c = Coordinator::new(pool)
    ignore(
      c.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "reader",
        provider_secret,
        ["self-hosted", "linux"],
        [protocol_repo],
      ),
    )
    let assignment = c.claim(provider_secret, claim_request()).unwrap()
    assert_eq(assignment.version, @protocol.release_assignment_version)
    let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
    ignore(c.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
    let grant = c.api_runtime(id, attempt_secret, {
      version: 1,
      execution_id: "e".repeat(32),
    })
    assert_eq(
      c.authenticate_job_api(grant.token, protocol_repo, "contents:read").id,
      actor.id,
    )
    try
      ignore(
        c.authenticate_job_api(grant.token, protocol_repo, "contents:write"),
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("read-only job could publish")
    }
  })
}
