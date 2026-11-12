///|
async test "provider access forms preserve selected grants and require administrator CSRF" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, cookie) => {
    let coordinator = @pipeline.Coordinator::new(pool)
    let admin = @identity.active_user_by_name(pool, "admin")
    let token = "a".repeat(64)
    let provider = coordinator.create_provider(
      admin,
      "access-test",
      token,
      ["self-hosted", "linux"],
      [{ owner: "alice", name: "demo", }],
    )
    let route = "/-/admin/pipelines/providers/" +
      provider.id.to_string() +
      "/access"
    let (page, body) = @web_testkit.http_get_path_with_cookie(
      port, route, cookie,
    )
    assert_eq(page.code, 200)
    assert_eq(page.headers.get("cache-control"), Some("no-store"))
    assert_true(body.contains("value=\"selected\" selected"))
    assert_true(body.contains("value=\"alice/demo\""))
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let (denied, _) = @web_testkit.http_get_path_with_cookie(port, route, alice)
    assert_eq(denied.code, 403)
    let (denied_post, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&scope=all",
      alice,
    )
    assert_eq(denied_post.code, 403)
    let (missing_csrf, _) = @web_testkit.http_post_path_with_cookie(
      port, route, "scope=all", cookie,
    )
    assert_eq(missing_csrf.code, 403)
    for invalid in ["unknown", ""] {
      let (response, _) = @web_testkit.http_post_path_with_cookie(
        port,
        route,
        "csrf_token=" + csrf + "&scope=" + invalid,
        cookie,
      )
      assert_eq(response.code, 400)
      assert_eq(
        coordinator.list_providers(admin)[0].scope,
        @pipeline.ProviderScope::parse("selected"),
      )
    }
    let (invalid, invalid_body) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&scope=selected&repositories=alice/%3Cbad%3E",
      cookie,
    )
    assert_eq(invalid.code, 400)
    assert_true(invalid_body.contains("value=\"alice/&lt;bad&gt;\""))
    assert_eq(coordinator.list_providers(admin)[0].repositories, ["alice/demo"])
    coordinator.set_provider_paused(admin, provider.id, true)
    let (shared, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&scope=all&repositories=alice/demo",
      cookie,
    )
    assert_eq(shared.code, 303)
    let current = coordinator.list_providers(admin)[0]
    assert_eq(current.scope, @pipeline.ProviderScope::parse("all"))
    assert_true(current.repositories.is_empty())
    assert_true(current.paused)
    let (_, listing) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/pipelines/providers?scope_saved=1", cookie,
    )
    assert_true(listing.contains("Provider access saved."))
    assert_true(
      listing.contains("All repositories (including new repositories)"),
    )
    assert_true(listing.contains("Never connected"))
    assert_false(listing.contains(token))
    assert_true(
      coordinator.claim(token, {
        version: 1,
        runner_os: None,
        request_id: "1".repeat(32),
        attempt_token: "b".repeat(64),
      })
      is None,
    )
    let (selected, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&scope=selected&repositories=alice/public",
      cookie,
    )
    assert_eq(selected.code, 303)
    assert_eq(coordinator.list_providers(admin)[0].repositories, [
      "alice/public",
    ])
    coordinator.revoke_provider(admin, provider.id)
    let (revoked, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&scope=all",
      cookie,
    )
    assert_eq(revoked.code, 404)
    let (_, revoked_list) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/pipelines/providers", cookie,
    )
    assert_false(revoked_list.contains(route))
  })
}

///|
async test "create provider supports explicit shared scope and defaults to selected" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, cookie) => {
    let coordinator = @pipeline.Coordinator::new(pool)
    let admin = @identity.active_user_by_name(pool, "admin")
    let (_, body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/pipelines/providers", cookie,
    )
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let (invalid, invalid_body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/admin/pipelines/providers",
      "csrf_token=" + csrf + "&name=preserved&labels=linux&scope=all",
      cookie,
    )
    assert_eq(invalid.code, 400)
    assert_true(invalid_body.contains("value=\"preserved\""))
    assert_true(invalid_body.contains("value=\"all\" selected"))
    for fields in ["&name=selected", "&name=shared&scope=all"] {
      let (created, _) = @web_testkit.http_post_path_with_cookie(
        port,
        "/-/admin/pipelines/providers",
        "csrf_token=" + csrf + "&labels=self-hosted,linux" + fields,
        cookie,
      )
      assert_eq(created.code, 200)
    }
    let providers = coordinator.list_providers(admin)
    assert_eq(providers[0].scope, @pipeline.ProviderScope::parse("selected"))
    assert_eq(providers[1].scope, @pipeline.ProviderScope::parse("all"))
  })
}

///|
async test "pipeline page explains no grant then no provider contact without leaking grants" {
  @test_support.with_git_test_repo((root, _) => {
    @web_testkit.with_ssh_settings_app(
      (port, pool, alice, _, _) => {
        let repo : @domain.RepoId = { owner: "alice", name: "demo", }
        ignore(
          @test_support.workflow_commit(
            repo.git_dir(root),
            @test_support.single_job_workflow,
          ),
        )
        let actor = @identity.active_user_by_name(pool, "alice")
        ignore(
          @pipeline.create_run(
            pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
          ),
        )
        let coordinator = @pipeline.Coordinator::new(pool)
        let admin = @identity.active_user_by_name(pool, "admin")
        let provider = coordinator.create_provider(
          admin,
          "private-provider",
          "b".repeat(64),
          ["self-hosted", "linux"],
          [{ owner: "alice", name: "public", }],
        )
        let (response, body) = @web_testkit.http_get_path_with_cookie(
          port, "/alice/demo/pipelines/1", alice,
        )
        assert_eq(response.code, 200)
        assert_true(
          body.contains("No provider is authorized for this repository."),
        )
        assert_false(body.contains("private-provider"))
        assert_false(body.contains("alice/public"))
        coordinator.set_provider_scope(
          admin,
          provider.id,
          @pipeline.ProviderScope::parse("all"),
          [],
        )
        let (_, updated) = @web_testkit.http_get_path_with_cookie(
          port, "/alice/demo/pipelines/1", alice,
        )
        assert_true(
          updated.contains(
            "No idle matching provider has contacted the server in the last minute.",
          ),
        )
        assert_true(updated.contains("Required labels: self-hosted, linux"))
      },
      repo_root=root,
    )
  })
}
