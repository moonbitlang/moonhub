///|
async fn api_test_request(
  port : Int32,
  path : String,
  token : String,
  body : Json?,
) -> (Int32, Json) {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let headers : @http.Headers = {
    "Authorization": "Bearer " + token,
    "Content-Type": "application/json",
  }
  let response = match body {
    None => client.get("/-/api/v1" + path, extra_headers=headers)
    Some(body) =>
      client.post("/-/api/v1" + path, body.stringify(), extra_headers=headers)
  }
  assert_eq(response.headers.get("cache-control"), Some("no-store"))
  (response.code, @json.parse(client.read_all().text()))
}

///|
async test "user API token authentication scope repository isolation and version bound writes" {
  @web_testkit.with_repository_test_app((port, pool, root, alice_cookie, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let bob = @identity.active_user_by_name(pool, "bob")
    let read = @identity.create_access_token(pool, alice, "read", "read", 1)
    let write = @identity.create_access_token(pool, alice, "write", "write", 1)
    let reviewer = @identity.create_access_token(
      pool, admin, "review", "write", 1,
    )
    let outsider = @identity.create_access_token(
      pool, bob, "outside", "read", 1,
    )
    let (status, _) = api_test_request(port, "/user", read, None)
    assert_eq(status, 200)
    let (outside, _) = api_test_request(
      port,
      "/repos/alice/demo/mrs",
      outsider,
      None,
    )
    assert_eq(outside, 404)
    let (cookie, _) = @web_testkit.http_get_path_with_cookie(
      port, "/-/api/v1/user", alice_cookie,
    )
    assert_eq(cookie.code, 401)
    let (denied, _) = api_test_request(
      port,
      "/repos/alice/demo/issues",
      read,
      Some({ "title": "Denied" }),
    )
    assert_eq(denied, 403)
    let (created, json) = api_test_request(
      port,
      "/repos/alice/demo/issues",
      write,
      Some({ "title": "CLI issue" }),
    )
    assert_eq(created, 200)
    assert_true(json is { "number": String("1"), .. })
    let git_dir = "\{root}/alice/demo.git"
    ignore(
      @test_support.merge_test_commit(
        git_dir,
        "cli",
        @gitops.branch_sha(git_dir, "master"),
        "cli\n",
      ),
    )
    let (created, mr) = api_test_request(
      port,
      "/repos/alice/demo/mrs",
      write,
      Some({ "title": "CLI MR", "source": "cli", "target": "master" }),
    )
    assert_eq(created, 200)
    assert_true(mr is { "version": String("1"), .. })
    let (approved, _) = api_test_request(
      port,
      "/repos/alice/demo/mrs/1/review",
      reviewer,
      Some({ "version": "1", "decision": "approved" }),
    )
    assert_eq(approved, 200)
    let (stale, _) = api_test_request(
      port,
      "/repos/alice/demo/mrs/1/review",
      reviewer,
      Some({ "version": "2", "decision": "approved" }),
    )
    assert_eq(stale, 400)
    let (execute_denied, _) = api_test_request(
      port,
      "/repos/alice/demo/mrs/1/approve-checks",
      write,
      Some({ "version": "1" }),
    )
    assert_eq(execute_denied, 403)
    let (merge_denied, _) = api_test_request(
      port,
      "/repos/alice/demo/mrs/1/merge",
      write,
      Some({ "version": "1" }),
    )
    assert_eq(merge_denied, 403)
    let (unknown_field, _) = api_test_request(
      port,
      "/repos/alice/demo/issues",
      write,
      Some({ "title": "Bad", "admin": "true" }),
    )
    assert_eq(unknown_field, 400)
    let (inbox, _) = api_test_request(port, "/inbox", write, None)
    assert_eq(inbox, 200)
    @identity.revoke_access_token(
      pool,
      alice,
      @identity.access_tokens(pool, alice)[0].id,
    )
    let (revoked, _) = api_test_request(port, "/user", write, None)
    assert_eq(revoked, 401)
  })
}

///|
async test "write tokens cannot implicitly approve MR execution and cancelled runs stay authorized" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let write = @identity.create_access_token(pool, alice, "write", "write", 1)
    let execute = @identity.create_access_token(
      pool, alice, "execute", "execute", 1,
    )
    let merge = @identity.create_access_token(pool, alice, "merge", "merge", 1)
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let git_dir = repo.git_dir(root)
    let workflow = "name: test\non: workflow_dispatch\njobs:\n  check:\n    runs-on: [self-hosted, linux]\n    steps:\n      - run: echo test\n"
    let base = @test_support.workflow_commit(git_dir, workflow)
    ignore(
      @gitops.merge_git(git_dir, ["update-ref", "refs/heads/master", base]),
    )
    ignore(@test_support.merge_test_commit(git_dir, "api", base, "api\n"))
    @collaboration.save_branch_rule(
      pool,
      scope,
      git_dir,
      alice,
      "master",
      true,
      0L,
      checks=[".github/workflows/build.yml"],
    )
    let (created, _) = api_test_request(
      port,
      "/repos/alice/demo/mrs",
      write,
      Some({
        "title": "No implicit execution",
        "source": "api",
        "target": "master",
      }),
    )
    assert_eq(created, 200)
    let mr = @collaboration.require_merge_request(pool, scope, 1L)
    assert_eq(
      @collaboration.merge_checks(pool, mr)[0].state,
      "awaiting_approval",
    )
    let (gated, _) = api_test_request(
      port,
      "/repos/alice/demo/mrs/1/merge",
      merge,
      Some({ "version": "1" }),
    )
    assert_eq(gated, 400)
    let (approved, _) = api_test_request(
      port,
      "/repos/alice/demo/mrs/1/approve-checks",
      execute,
      Some({ "version": "1" }),
    )
    assert_eq(approved, 200)
    let (created, run) = api_test_request(
      port,
      "/repos/alice/demo/runs",
      execute,
      Some({ "branch": "master", "workflow": ".github/workflows/build.yml" }),
    )
    assert_eq(created, 200)
    guard run is { "number": String(number), .. } else { fail("run missing") }
    let (cancelled, _) = api_test_request(
      port,
      "/repos/alice/demo/runs/\{number}/cancel",
      execute,
      Some({}),
    )
    assert_eq(cancelled, 200)
    let (rerun, _) = api_test_request(
      port,
      "/repos/alice/demo/runs/\{number}/rerun",
      execute,
      Some({}),
    )
    assert_eq(rerun, 200)
  })
}

///|
async test "optional pull request discovery cannot turn API write permission into execution authority" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let write = @identity.create_access_token(pool, actor, "writer", "write", 1)
    let execute = @identity.create_access_token(
      pool, actor, "executor", "execute", 1,
    )
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let dir = repo.git_dir(root)
    let base = @test_support.workflow_commit(
      dir,
      @test_support.single_job_workflow.replace_all(
        old="workflow_dispatch",
        new="pull_request",
      ),
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", base]))
    ignore(@test_support.merge_test_commit(dir, "api", base, "optional\n"))
    assert_eq(
      api_test_request(
        port,
        "/repos/alice/demo/mrs",
        write,
        Some({ "title": "Optional CI", "source": "api", "target": "master" }),
      ).0,
      200,
    )
    assert_true(@pipeline.run_next_merge_check(pool, root))
    let mr = @collaboration.require_merge_request(pool, scope, 1L)
    assert_eq(
      @collaboration.merge_checks(pool, mr)[0].state,
      "awaiting_approval",
    )
    assert_true(@pipeline.list_runs(pool, actor, repo).is_empty())
    let (status, json) = api_test_request(
      port,
      "/repos/alice/demo/mrs/1/checks",
      write,
      None,
    )
    assert_eq(status, 200)
    assert_true(
      json
      is {
        "checks": Array(
          [{ "required": False, "status": String("awaiting_approval"), .. }]
        ),
        ..
      },
    )
    assert_eq(
      api_test_request(
        port,
        "/repos/alice/demo/mrs/1/approve-checks",
        write,
        Some({ "version": "1" }),
      ).0,
      403,
    )
    assert_eq(
      api_test_request(
        port,
        "/repos/alice/demo/mrs/1/approve-checks",
        execute,
        Some({ "version": "1" }),
      ).0,
      200,
    )
    pool.with_client(client => {
      ignore(client.execute("UPDATE merge_request SET checks_poll_after = 0"))
    })
    assert_true(@pipeline.run_next_merge_check(pool, root))
    assert_eq(@pipeline.list_runs(pool, actor, repo).length(), 1)
  })
}
