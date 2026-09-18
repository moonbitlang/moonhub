///|
async test "pipeline pages list runs, show jobs, and cancel with CSRF" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    ignore(
      @test_support.workflow_commit(
        repo.git_dir(@web_testkit.test_repo_root),
        @test_support.single_job_workflow,
      ),
    )
    let run = @pipeline.create_run(
      pool,
      @web_testkit.test_repo_root,
      @identity.active_user_by_name(pool, "alice"),
      repo,
      "pipeline",
      ".github/workflows/build.yml",
    )
    let (list_response, list_body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/pipelines", alice,
    )
    assert_eq(list_response.code, 200)
    assert_true(list_body.contains("Pipelines"))
    assert_true(list_body.contains("/alice/demo/pipelines/1"))
    let (detail_response, detail_body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/pipelines/1", alice,
    )
    assert_eq(detail_response.code, 200)
    assert_true(detail_body.contains("Protocol fixture"))
    assert_true(detail_body.contains("build"))
    assert_true(detail_body.contains("name=\"csrf_token\""))
    let csrf = @web_testkit.extract_attr(
      detail_body, "name=\"csrf_token\"", "value=\"",
    )
    let (cancel_response, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/pipelines/1/cancel",
      "csrf_token=" + csrf,
      alice,
    )
    assert_eq(cancel_response.code, 303)
    let conclusion = @pipeline.get_run(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        repo,
        run.number,
      ).conclusion
    assert_true(conclusion is Some(@pipeline.Cancelled))
  })
}
