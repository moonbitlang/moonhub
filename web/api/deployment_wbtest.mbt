///|
async test "environment API preserves revisions hides credentials and binds reviews on both mounts" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let read = @identity.create_access_token(pool, actor, "read", "read", 1)
    let write = @identity.create_access_token(pool, actor, "write", "write", 1)
    let execute = @identity.create_access_token(
      pool, actor, "execute", "execute", 1,
    )
    let route = "/repos/alice/demo/environments/production"
    let body : Json = { "version": "0", "reviewers": [actor.id.to_string()] }
    assert_eq(api_test_request(port, route, read, Some(body)).0, 403)
    assert_eq(api_test_request(port, route, write, Some(body)).0, 200)
    assert_eq(api_test_request(port, route, write, Some(body)).0, 409)
    assert_eq(
      api_test_request(
        port,
        route + "/secrets/TOKEN",
        write,
        Some({ "version": "0", "value": "environment-private-token" }),
      ).0,
      200,
    )
    assert_eq(
      api_test_request(
        port,
        route + "/variables/REGION",
        write,
        Some({ "version": "0", "value": "saved-region" }),
      ).0,
      200,
    )
    let (_, listed) = api_test_request(
      port,
      "/repos/alice/demo/environments",
      read,
      None,
    )
    assert_true(listed.stringify().contains("saved-region"))
    assert_false(listed.stringify().contains("environment-private-token"))
    let source = @test_support.single_job_workflow.replace_all(
      old="    runs-on:",
      new="    environment: production\n    runs-on:",
    )
    ignore(@test_support.workflow_commit(repo.git_dir(root), source))
    let run = @pipeline.create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    let deployment = @runtime.job_deployments(pool, actor, repo, run.number)[0]
    let review_route = "/repos/alice/demo/runs/" +
      run.number.to_string() +
      "/deployments/" +
      deployment.job_id.to_string()
    let review : Json = {
      "environment_id": deployment.environment_id.to_string(),
      "policy_version": deployment.policy_version.to_string(),
      "decision": "approved",
    }
    assert_eq(api_test_request(port, review_route, write, Some(review)).0, 403)
    assert_eq(
      api_test_request(
        port,
        review_route,
        execute,
        Some({
          "environment_id": deployment.environment_id.to_string(),
          "policy_version": "999",
          "decision": "approved",
        }),
      ).0,
      409,
    )
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let response = client
      ..request(Post, "/api/v3" + review_route, extra_headers={
        "Authorization": "Bearer " + execute,
        "Content-Type": "application/json",
      })
      ..write(review.stringify())
      .end_request()
    assert_eq(response.code, 200)
    ignore(client.read_all())
    assert_eq(
      api_test_request(port, review_route, execute, Some(review)).0,
      200,
    )
    let (_, detail) = api_test_request(
      port,
      "/repos/alice/demo/runs/" + run.number.to_string(),
      read,
      None,
    )
    assert_true(detail.stringify().contains("approved"))
    assert_false(detail.stringify().contains("environment-private-token"))
  })
}
