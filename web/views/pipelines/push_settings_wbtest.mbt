///|
async test "automatic push settings require a repository manager and CSRF and default off" {
  @test_support.with_git_test_repo((root, _) => {
    @web_testkit.with_ssh_settings_app(
      (port, pool, alice, bob, _) => {
        let repo : @domain.RepoId = { owner: "alice", name: "demo", }
        let actor = @identity.active_user_by_name(pool, "alice")
        assert_false(@repository.pipeline_push_enabled(pool, actor, repo))
        let page = "/alice/demo/pipelines?tab=settings"
        let (settings, body) = @web_testkit.http_get_path_with_cookie(
          port, page, alice,
        )
        assert_eq(settings.code, 200)
        assert_true(
          body.contains("href=\"\{page}\" aria-label=\"Actions configuration\""),
        )
        assert_true(body.contains("Run push workflows"))
        assert_false(body.contains("data-sidebar-collapse aria-controls"))
        assert_false(body.contains("aria-label=\"Actions views\""))
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
        let (outside, _) = @web_testkit.http_get_path_with_cookie(
          port, page, bob,
        )
        assert_eq(outside.code, 404)
        pool.with_client(client => {
          let _ = client.execute(
            "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
          )
        })
        let (member_page, denied_body) = @web_testkit.http_get_path_with_cookie(
          port, page, bob,
        )
        assert_eq(member_page.code, 403)
        assert_false(denied_body.contains("Run push workflows"))
        let (member_post, _) = @web_testkit.http_post_path_with_cookie(
          port,
          route,
          "push_enabled=1&csrf_token=" + csrf,
          bob,
        )
        assert_eq(member_post.code, 403)
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
          assert_eq(saved.headers.get("location"), Some(page + "&saved=1"))
          let (_, saved_body) = @web_testkit.http_get_path_with_cookie(
            port,
            page + "&saved=1",
            alice,
          )
          assert_true(saved_body.contains("Actions settings saved."))
          assert_eq(
            saved_body.contains("name=\"push_enabled\" value=\"1\" checked"),
            enabled,
          )
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
