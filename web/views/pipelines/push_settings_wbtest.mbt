///|
async test "automatic push settings require a repository manager and CSRF and default off" {
  @test_support.with_git_test_repo((root, _) => {
    @web_testkit.with_ssh_settings_app(
      (port, pool, alice, bob, _) => {
        let repo : @domain.RepoId = { owner: "alice", name: "demo", }
        let actor = @identity.active_user_by_name(pool, "alice")
        assert_false(@repository.pipeline_push_enabled(pool, actor, repo))
        let (_, body) = @web_testkit.http_get_path_with_cookie(
          port, "/alice/demo/pipelines", alice,
        )
        assert_true(body.contains("Run push workflows"))
        let csrf = @web_testkit.extract_attr(
          body, "name=\"csrf_token\"", "value=\"",
        )
        let route = "/alice/demo/pipelines/settings"
        let (denied, _) = @web_testkit.http_post_path_with_cookie(
          port, route, "push_enabled=1", alice,
        )
        assert_eq(denied.code, 403)
        let (other, _) = @web_testkit.http_post_path_with_cookie(
          port,
          route,
          "push_enabled=1&csrf_token=" + csrf,
          bob,
        )
        assert_eq(other.code, 404)
        for enabled in [true, false] {
          let (saved, _) = @web_testkit.http_post_path_with_cookie(
            port,
            route,
            "csrf_token=" +
            csrf +
            (if enabled { "&push_enabled=1" } else { "" }),
            alice,
          )
          assert_eq(saved.code, 303)
          assert_eq(
            @repository.pipeline_push_enabled(pool, actor, repo),
            enabled,
          )
        }
      },
      repo_root=root,
    )
  })
}
