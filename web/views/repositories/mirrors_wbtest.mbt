///|
async test "mirror forms enforce authorization CSRF versions and preserve validation input" {
  @test_support.with_git_test_repo((root, dir) => {
    let config = @test_support.mock_import_config(root, dir)
    @web_testkit.with_ssh_settings_app(
      (port, pool, alice, bob, _) => {
        let route = "/alice/demo/settings/mirrors"
        let (response, body) = @web_testkit.http_get_path_with_cookie(
          port, route, alice,
        )
        assert_eq(response.code, 200)
        assert_true(body.contains("No push mirrors yet"))
        assert_eq(response.headers.get("cache-control"), Some("no-store"))
        let (_, form) = @web_testkit.http_get_path_with_cookie(
          port,
          route + "/new",
          alice,
        )
        let csrf = @web_testkit.extract_attr(
          form, "name=\"csrf_token\"", "value=\"",
        )
        assert_false(form.contains("name=\"force_push\" value=\"1\" checked"))
        assert_false(form.contains("name=\"prune\" value=\"1\" checked"))
        let fields = "csrf_token=\{csrf}&url=git%40source.example%3Aorg%2Fdemo.git&active=1"
        let (bad_csrf, _) = @web_testkit.http_post_path_with_cookie(
          port, route, "url=git%40source.example%3Aorg%2Fdemo.git", alice,
        )
        assert_eq(bad_csrf.code, 403)
        let (created, _) = @web_testkit.http_post_path_with_cookie(
          port, route, fields, alice,
        )
        assert_eq(created.code, 303)
        let actor = @identity.active_user_by_name(pool, "alice")
        let repo : @domain.RepoId = { owner: "alice", name: "demo", }
        let mirror = @repository.push_mirrors(pool, actor, repo)[0]
        let edit = route + "/" + mirror.id.to_string()
        pool.with_client(client => {
          ignore(
            client.execute(
              "UPDATE repository_mirror SET status='succeeded',last_success_at=datetime('now') WHERE id=?",
              params=[mirror.id],
            ),
          )
          ignore(
            client.execute(
              "INSERT INTO mirror_attempt(mirror_id,generation,status,completed_at) VALUES(?,1,'succeeded',datetime('now'))",
              params=[mirror.id],
            ),
          )
        })
        let (invalid, body) = @web_testkit.http_post_path_with_cookie(
          port,
          edit,
          "csrf_token=\{csrf}&version=1&url=git%40denied.example%3Aorg%2Fdemo.git&prune=1",
          alice,
        )
        assert_eq(invalid.code, 400)
        assert_true(body.contains("git@denied.example:org/demo.git"))
        assert_true(body.contains("name=\"prune\" value=\"1\" checked"))
        assert_true(body.contains("Current status: Up to date"))
        assert_false(body.contains("No sync attempts yet."))
        let (outside, _) = @web_testkit.http_get_path_with_cookie(
          port, route, bob,
        )
        assert_eq(outside.code, 404)
        pool.with_client(client => {
          ignore(
            client.execute(
              "INSERT INTO team_member(team_id,user_id,role) VALUES(1,2,'member')",
            ),
          )
        })
        let (contributor, _) = @web_testkit.http_get_path_with_cookie(
          port, route, bob,
        )
        assert_eq(contributor.code, 403)
        let (synced, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/sync",
          "csrf_token=\{csrf}&version=1",
          alice,
        )
        assert_eq(synced.code, 303)
        let (stale, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/delete",
          "csrf_token=\{csrf}&version=1",
          alice,
        )
        assert_eq(stale.code, 400)
        let (deleted, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/delete",
          "csrf_token=\{csrf}&version=2",
          alice,
        )
        assert_eq(deleted.code, 303)
        assert_true(@repository.push_mirrors(pool, actor, repo).is_empty())
      },
      repo_root=root,
      import_config=Some(config),
    )
  })
}
