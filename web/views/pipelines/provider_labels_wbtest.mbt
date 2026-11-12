///|
async test "provider label forms preserve errors, enforce admin and CSRF, and keep existing identity" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, admin_cookie) => {
    let coordinator = @pipeline.Coordinator::new(pool)
    let admin = @identity.active_user_by_name(pool, "admin")
    let token = "d".repeat(64)
    let provider = coordinator.create_provider(
      admin,
      "editable",
      token,
      ["self-hosted", "linux"],
      [{ owner: "alice", name: "demo", }],
    )
    let route = "/-/admin/pipelines/providers/" +
      provider.id.to_string() +
      "/labels"
    let (listed, list_body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/pipelines/providers", admin_cookie,
    )
    assert_eq(listed.code, 200)
    assert_true(list_body.contains(route))
    let (form, body) = @web_testkit.http_get_path_with_cookie(
      port, route, admin_cookie,
    )
    assert_eq(form.code, 200)
    assert_eq(form.headers.get("cache-control"), Some("no-store"))
    assert_true(body.contains("value=\"linux,self-hosted\""))
    assert_false(body.contains(token))
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let (forbidden, _) = @web_testkit.http_get_path_with_cookie(
      port, route, alice,
    )
    assert_eq(forbidden.code, 403)
    let (forbidden_post, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&labels=self-hosted,linux,moonhub-build",
      alice,
    )
    assert_eq(forbidden_post.code, 403)
    let (no_csrf, _) = @web_testkit.http_post_path_with_cookie(
      port, route, "labels=self-hosted,linux,moonhub-build", admin_cookie,
    )
    assert_eq(no_csrf.code, 403)
    let (invalid, invalid_body) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&labels=self-hosted,linux,%3Cscript%3E",
      admin_cookie,
    )
    assert_eq(invalid.code, 400)
    assert_eq(
      @web_testkit.extract_attr(
        invalid_body, "id=\"provider-labels\"", "value=\"",
      ),
      "self-hosted,linux,&lt;script&gt;",
    )
    assert_true(invalid_body.contains("aria-invalid=\"true\""))
    assert_true(invalid_body.contains("role=\"alert\""))
    assert_eq(coordinator.list_providers(admin)[0].labels, [
      "linux", "self-hosted",
    ])
    coordinator.set_provider_paused(admin, provider.id, true)
    let (saved, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=" + csrf + "&labels=SELF-HOSTED,%20linux%20,moonhub-build",
      admin_cookie,
    )
    assert_eq(saved.code, 303)
    assert_eq(
      saved.headers.get("location"),
      Some("/-/admin/pipelines/providers?labels_saved=1"),
    )
    let updated = coordinator.list_providers(admin)[0]
    assert_eq(updated.id, provider.id)
    assert_true(updated.paused)
    assert_eq(updated.labels, ["linux", "moonhub-build", "self-hosted"])
    assert_true(
      coordinator.claim(token, {
        version: 1,
        runner_os: None,
        request_id: "1".repeat(32),
        attempt_token: "b".repeat(64),
      })
      is None,
    )
    let (confirmation, confirmation_body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/pipelines/providers?labels_saved=1", admin_cookie,
    )
    assert_eq(confirmation.code, 200)
    assert_true(confirmation_body.contains("Provider labels saved."))
    coordinator.revoke_provider(admin, provider.id)
    let (_, revoked_list) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/pipelines/providers", admin_cookie,
    )
    assert_false(revoked_list.contains(route))
    for missing in [route, "/-/admin/pipelines/providers/9999/labels"] {
      let (get, _) = @web_testkit.http_get_path_with_cookie(
        port, missing, admin_cookie,
      )
      assert_eq(get.code, 404)
      let (post, _) = @web_testkit.http_post_path_with_cookie(
        port,
        missing,
        "csrf_token=" + csrf + "&labels=self-hosted,linux",
        admin_cookie,
      )
      assert_eq(post.code, 404)
    }
  })
}

///|
async test "saving provider labels unblocks queued work and cancels incompatible running work" {
  @test_support.with_git_test_repo((root, _) => {
    @web_testkit.with_ssh_settings_app(
      (port, pool, _, _, cookie) => {
        let admin = @identity.active_user_by_name(pool, "admin")
        let actor = @identity.active_user_by_name(pool, "alice")
        let repo : @domain.RepoId = { owner: "alice", name: "demo", }
        let workflow =
          #|name: Dynamic labels
          #|on: workflow_dispatch
          #|jobs:
          #|  check:
          #|    runs-on: [self-hosted, linux, moonhub-build]
          #|    steps:
          #|      - run: echo checked
        ignore(@test_support.workflow_commit(repo.git_dir(root), workflow))
        let run = @pipeline.create_run(
          pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
        )
        let coordinator = @pipeline.Coordinator::new(pool)
        let provider_token = "a".repeat(64)
        let provider = coordinator.create_provider(
          admin,
          "dynamic",
          provider_token,
          ["self-hosted", "linux"],
          [repo],
        )
        let claim : @protocol.ClaimRequest = {
          version: 1,
          runner_os: None,
          request_id: "1".repeat(32),
          attempt_token: "b".repeat(64),
        }
        assert_true(coordinator.claim(provider_token, claim) is None)
        let route = "/-/admin/pipelines/providers/" +
          provider.id.to_string() +
          "/labels"
        let (_, body) = @web_testkit.http_get_path_with_cookie(
          port, route, cookie,
        )
        let csrf = @web_testkit.extract_attr(
          body, "name=\"csrf_token\"", "value=\"",
        )
        let (updated, _) = @web_testkit.http_post_path_with_cookie(
          port,
          route,
          "csrf_token=" + csrf + "&labels=self-hosted,linux,moonhub-build",
          cookie,
        )
        assert_eq(updated.code, 303)
        let assignment = coordinator.claim(provider_token, claim).unwrap()
        assert_eq(assignment.run_id, run.id.to_string())
        let attempt_id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
        ignore(coordinator.start(attempt_id, claim.attempt_token, 1))
        let (removed, _) = @web_testkit.http_post_path_with_cookie(
          port,
          route,
          "csrf_token=" + csrf + "&labels=self-hosted,linux",
          cookie,
        )
        assert_eq(removed.code, 303)
        assert_true(
          coordinator.heartbeat(attempt_id, claim.attempt_token, 1).cancel_requested,
        )
        assert_eq(
          coordinator.complete(attempt_id, claim.attempt_token, {
            version: 1,
            conclusion: "cancelled",
            last_log_sequence: "0",
            outputs: Map([]),
          }).conclusion,
          "cancelled",
        )
      },
      repo_root=root,
    )
  })
}
