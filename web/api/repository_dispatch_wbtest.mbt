///|
async test "repository dispatch requires execution authority snapshots payload and deduplicates across both API mounts" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    pool.with_client(c => {
      ignore(
        c.execute("UPDATE repository SET default_branch='master' WHERE id=1"),
      )
    })
    let dir = repo.git_dir(root)
    let source = @test_support.single_job_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: {repository_dispatch: {types: [build]}}",
    )
    let sha = @test_support.workflow_commit(dir, source)
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", sha]))
    let execute = @identity.create_access_token(
      pool, actor, "dispatch", "execute", 1,
    )
    let write = @identity.create_access_token(
      pool, actor, "metadata", "write", 1,
    )
    let body : Json = {
      "event_type": "build",
      "request_id": "fixed-request",
      "client_payload": { "flag": true, "items": ["one", 2] },
    }
    let route = "/repos/alice/demo/dispatches"
    assert_eq(api_test_request(port, route, write, Some(body)).0, 403)
    let (status, accepted) = api_test_request(port, route, execute, Some(body))
    assert_eq(status, 200)
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let response = client
      ..request(Post, "/api/v3" + route, extra_headers={
        "Authorization": "Bearer " + execute,
        "Content-Type": "application/json",
      })
      ..write(body.stringify())
      .end_request()
    assert_eq(response.code, 200)
    assert_eq(@json.parse(client.read_all().text()), accepted)
    assert_eq(
      api_test_request(
        port,
        route,
        execute,
        Some({ "event_type": "other", "request_id": "fixed-request" }),
      ).0,
      409,
    )
    let later = @test_support.workflow_commit(
      dir, @test_support.single_job_workflow,
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", later]))
    assert_true(@pipeline.run_next_workflow_event(pool, root))
    assert_false(@pipeline.run_next_workflow_event(pool, root))
    let runs = @runtime.list_runs(pool, actor, repo)
    assert_eq(runs.length(), 1)
    assert_eq(runs[0].commit_sha, sha)
    assert_eq(runs[0].context.unwrap().event_name, "repository_dispatch")
    assert_true(
      runs[0].context.unwrap().event.unwrap().get("client_payload")
      is Some({ "flag": true, "items": ["one", 2], .. }),
    )
    assert_eq(
      api_test_request(port, route, execute, Some({ "event_type": "other" })).0,
      200,
    )
    assert_true(@pipeline.run_next_workflow_event(pool, root))
    assert_eq(@runtime.list_runs(pool, actor, repo).length(), 1)
    assert_eq(
      api_test_request(
        port,
        route,
        execute,
        Some({ "event_type": "build", "client_payload": [] }),
      ).0,
      400,
    )
  })
}
