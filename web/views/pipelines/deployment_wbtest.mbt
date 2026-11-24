///|
async test "deployment settings forms require CSRF escape public values and never echo secrets" {
  @web_testkit.with_repository_test_app((port, pool, _, alice, bob) => {
    let base = "/alice/demo/settings/environments"
    let (_, form) = @web_testkit.http_get_path_with_cookie(port, base, alice)
    let csrf = @web_testkit.extract_attr(
      form, "name=\"csrf_token\"", "value=\"",
    )
    let body = "name=production&version=0&reviewers=alice"
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, base, body, alice).0.code,
      403,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        base,
        body + "&csrf_token=" + csrf,
        alice,
      ).0.code,
      303,
    )
    assert_eq(
      @web_testkit.http_get_path_with_cookie(port, base, bob).0.code,
      404,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        base + "/production/variables",
        "name=REGION&version=0&value=%3Cscript%3Ex%3C%2Fscript%3E&csrf_token=" +
        csrf,
        alice,
      ).0.code,
      303,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        base + "/production/secrets",
        "name=TOKEN&version=0&value=environment-private-value&csrf_token=" +
        csrf,
        alice,
      ).0.code,
      303,
    )
    let (_, saved) = @web_testkit.http_get_path_with_cookie(port, base, alice)
    assert_true(saved.contains("&lt;script&gt;x&lt;/script&gt;"))
    assert_false(saved.contains("<script>x</script>"))
    assert_false(saved.contains("environment-private-value"))
    assert_true(saved.contains("Reviewers: alice"))
    let actor = @identity.active_user_by_name(pool, "alice")
    let config = @runtime.list_deployment_environments(pool, actor, {
        owner: "alice",
        name: "demo",
      })[0]
    assert_eq(config.reviewers, [actor.id])
  })
}

///|
async test "run page presents deployment review and records rejection with CSRF" {
  @web_testkit.with_repository_test_app((port, pool, root, alice, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let c = @runtime.Coordinator::new(pool)
    c.save_deployment_environment(actor, repo, "production", 0L, [actor.id])
    let source = @test_support.single_job_workflow.replace_all(
      old="    runs-on:",
      new="    environment: production\n    runs-on:",
    )
    ignore(@test_support.workflow_commit(repo.git_dir(root), source))
    let run = @pipeline.create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    let item = @runtime.job_deployments(pool, actor, repo, run.number)[0]
    let path = "/alice/demo/pipelines/" + run.number.to_string()
    let (response, page) = @web_testkit.http_get_path_with_cookie(
      port, path, alice,
    )
    assert_eq(response.code, 200)
    assert_true(page.contains("Approve deployment"))
    assert_true(page.contains("Waiting for deployment environment approval"))
    assert_true(
      page.contains("Deployment environment: <strong>production</strong>"),
    )
    let csrf = @web_testkit.extract_attr(
      page, "name=\"csrf_token\"", "value=\"",
    )
    let fields = "environment_id=" +
      item.environment_id.to_string() +
      "&policy_version=" +
      item.policy_version.to_string() +
      "&decision=rejected"
    let review = path + "/deployments/" + item.job_id.to_string()
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, review, fields, alice).0.code,
      403,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        review,
        fields + "&csrf_token=" + csrf,
        alice,
      ).0.code,
      303,
    )
    let (_, rejected) = @web_testkit.http_get_path_with_cookie(
      port, path, alice,
    )
    assert_true(rejected.contains("rejected"))
    assert_false(rejected.contains("Approve deployment"))
  })
}
