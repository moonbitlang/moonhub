///|
async test "run API selects original PR workflow jobs with execute permission and leaves source pinned" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let execute = @identity.create_access_token(
      pool, actor, "select-jobs", "execute", 1,
    )
    let write = @identity.create_access_token(
      pool, actor, "no-execution", "write", 1,
    )
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let source = @test_support.single_job_workflow.replace_all(
      old="workflow_dispatch",
      new="pull_request",
    )
    let sha = @test_support.workflow_commit(repo.git_dir(root), source)
    let request : Json = {
      "branch": "pipeline",
      "workflow": ".github/workflows/build.yml",
      "jobs": ["build"],
    }
    assert_eq(
      api_test_request(port, "/repos/alice/demo/runs", write, Some(request)).0,
      403,
    )
    for
      jobs in [
        Json("build"),
        Json([1]),
        Json(["missing"]),
        Json(["build", "build"]),
      ] {
      let (status, _) = api_test_request(
        port,
        "/repos/alice/demo/runs",
        execute,
        Some({
          "branch": "pipeline",
          "workflow": ".github/workflows/build.yml",
          "jobs": jobs,
        }),
      )
      assert_eq(status, 400)
    }
    let (status, _) = api_test_request(
      port,
      "/repos/alice/demo/runs",
      execute,
      Some(request),
    )
    assert_eq(status, 200)
    assert_eq(@gitops.branch_sha(repo.git_dir(root), "pipeline"), sha)
    assert_eq(@pipeline.get_run(pool, actor, repo, 1L).workflow_source, source)
  })
}

///|
async test "run API accepts typed dispatch inputs and rejects invalid input objects" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let execute = @identity.create_access_token(
      pool, actor, "dispatch", "execute", 1,
    )
    let write = @identity.create_access_token(pool, actor, "write", "write", 1)
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let workflow = @test_support.single_job_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on:\n  workflow_dispatch:\n    inputs:\n      version: {type: string, required: true}\n      release: {type: boolean, default: false}\n      count: {type: number, default: 1}\n      channel: {type: choice, options: [stable, beta], default: stable}",
    )
    ignore(@test_support.workflow_commit(repo.git_dir(root), workflow))
    let (denied, _) = api_test_request(
      port,
      "/repos/alice/demo/runs",
      write,
      Some({
        "branch": "pipeline",
        "workflow": ".github/workflows/build.yml",
        "inputs": { "version": "1.2.3" },
      }),
    )
    assert_eq(denied, 403)
    for
      inputs in [
        Json("bad"),
        Json::null(),
        Json({ "unknown": "value" }),
        Json({ "version": "1.2.3", "release": "not-a-boolean" }),
        Json({ "version": "1.2.3", "channel": "nightly" }),
        Json::object(Map([])),
      ] {
      let (invalid, _) = api_test_request(
        port,
        "/repos/alice/demo/runs",
        execute,
        Some({
          "branch": "pipeline",
          "workflow": ".github/workflows/build.yml",
          "inputs": inputs,
        }),
      )
      assert_eq(invalid, 400)
    }
    let (created, run) = api_test_request(
      port,
      "/repos/alice/demo/runs",
      execute,
      Some({
        "branch": "pipeline",
        "workflow": ".github/workflows/build.yml",
        "inputs": { "version": "1.2.3", "release": true, "count": 2.5 },
      }),
    )
    assert_eq(created, 200)
    assert_true(
      run
      is {
        "number": String("1"),
        "context": {
          "inputs": {
            "version": String("1.2.3"),
            "release": True,
            "count": Number(2.5, ..),
            "channel": String("stable"),
            ..
          },
          ..
        },
        ..
      },
    )
  })
}

///|
async test "run API transports the maximum UTF8 dispatch payload and rejects larger inputs" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let token = @identity.create_access_token(
      pool, actor, "dispatch", "execute", 1,
    )
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let workflow = @test_support.single_job_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on:\n  workflow_dispatch:\n    inputs:\n      payload: {required: true}",
    )
    ignore(@test_support.workflow_commit(repo.git_dir(root), workflow))
    let overhead = @utf8.encode(Json({ "payload": "" }).stringify()).length()
    let remaining = 65535 - overhead
    let value = "文".repeat(remaining / 3) + "a".repeat(remaining % 3)
    let inputs : Json = { "payload": value }
    assert_eq(@utf8.encode(inputs.stringify()).length(), 65535)
    let body : Json = {
      "branch": "pipeline",
      "workflow": ".github/workflows/build.yml",
      "inputs": inputs,
    }
    assert_true(@utf8.encode(body.stringify()).length() > 65536)
    let (created, run) = api_test_request(
      port,
      "/repos/alice/demo/runs",
      token,
      Some(body),
    )
    assert_eq(created, 200)
    assert_true(
      run is { "context": { "inputs": Object(actual), .. }, .. } &&
      actual.get("payload") == Some(Json(value)),
    )
    let (invalid, error) = api_test_request(
      port,
      "/repos/alice/demo/runs",
      token,
      Some({
        "branch": "pipeline",
        "workflow": ".github/workflows/build.yml",
        "inputs": { "payload": value + "x" },
      }),
    )
    assert_eq(invalid, 400)
    assert_true(error.stringify().contains("65535"))
    let (oversized, error) = api_test_request(
      port,
      "/repos/alice/demo/runs",
      token,
      Some({ "branch": "x".repeat(73728), "workflow": "build.yml" }),
    )
    assert_eq(oversized, 400)
    assert_true(
      error
      is { "error": { "message": String("request body is too large"), .. }, .. },
    )
    let (unchanged, error) = api_test_request(
      port,
      "/repos/alice/demo/runs/1/rerun",
      token,
      Some({ "padding": "x".repeat(65536) }),
    )
    assert_eq(unchanged, 400)
    assert_true(
      error
      is { "error": { "message": String("request body is too large"), .. }, .. },
    )
    assert_eq(@pipeline.list_runs(pool, actor, repo).length(), 1)
  })
}
