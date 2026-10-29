///|
async test "mirror forms enforce authorization CSRF versions and preserve validation input" {
  @test_support.with_git_test_repo((root, _) => {
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
        assert_false(form.contains("name=\"active\" value=\"1\" checked"))
        assert_false(form.contains("name=\"force_push\" value=\"1\" checked"))
        assert_false(form.contains("name=\"prune\" value=\"1\" checked"))
        let fields = "csrf_token=\{csrf}&url=git%40source.example%3Aorg%2Fdemo.git"
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
        // Fixture trust for the existing sync/version authorization cases.
        pool.with_client(client => {
          ignore(
            client.execute(
              "UPDATE repository_mirror SET host_keys=?,active=1,status='pending'",
              params=[@test_support.test_ssh_public_key],
            ),
          )
        })
        let mirror = @repository.push_mirrors(pool, actor, repo)[0]
        let edit = route + "/" + mirror.id.to_string()
        let (_, settings) = @web_testkit.http_get_path_with_cookie(
          port, edit, alice,
        )
        assert_true(settings.contains(mirror.public_key))
        assert_true(settings.contains("readonly"))
        assert_false(settings.contains("PRIVATE KEY"))
        assert_true(body.contains("No push mirrors yet"))
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
          "csrf_token=\{csrf}&version=1&url=git%40denied.example%3Aorg%2Fdemo.git&active=1&prune=1&host_keys=invalid",
          alice,
        )
        assert_eq(invalid.code, 400)
        assert_true(body.contains("git@denied.example:org/demo.git"))
        assert_true(body.contains("name=\"prune\" value=\"1\" checked"))
        assert_true(body.contains("Current status: Up to date"))
        assert_false(body.contains("No sync attempts yet."))
        assert_true(body.contains(mirror.public_key))
        assert_false(body.contains("PRIVATE KEY"))
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
        let (rotation_csrf, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/rotate-key",
          "version=2",
          alice,
        )
        assert_eq(rotation_csrf.code, 403)
        let (forbidden_rotation, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/rotate-key",
          "csrf_token=\{csrf}&version=2",
          bob,
        )
        assert_eq(forbidden_rotation.code, 403)
        let (stale_rotation, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/rotate-key",
          "csrf_token=\{csrf}&version=1",
          alice,
        )
        assert_eq(stale_rotation.code, 400)
        let (rotated, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/rotate-key",
          "csrf_token=\{csrf}&version=2",
          alice,
        )
        assert_eq(rotated.code, 303)
        let updated = @repository.push_mirrors(pool, actor, repo)[0]
        assert_false(updated.public_key == mirror.public_key)
        assert_false(updated.active)
        assert_eq(updated.version, 3L)
        let (_, settings) = @web_testkit.http_get_path_with_cookie(
          port, edit, alice,
        )
        assert_true(settings.contains(updated.public_key))
        assert_false(settings.contains(mirror.public_key))
        assert_false(settings.contains("PRIVATE KEY"))
        let (deleted, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/delete",
          "csrf_token=\{csrf}&version=3",
          alice,
        )
        assert_eq(deleted.code, 303)
        assert_true(@repository.push_mirrors(pool, actor, repo).is_empty())
      },
      repo_root=root,
    )
  })
}

///|
async test "mirror save reports missing destination policy instead of a server error" {
  @test_support.with_git_test_repo((root, _) => {
    @web_testkit.with_ssh_settings_app(
      (port, pool, alice, _, _) => {
        let route = "/alice/demo/settings/mirrors"
        let (_, form) = @web_testkit.http_get_path_with_cookie(
          port,
          route + "/new",
          alice,
        )
        let csrf = @web_testkit.extract_attr(
          form, "name=\"csrf_token\"", "value=\"",
        )
        let fields = "csrf_token=\{csrf}&url=git%40source.example%3Aorg%2Fdemo.git&active=1&force_push=1&prune=1"
        let (response, body) = @web_testkit.http_post_path_with_cookie(
          port, route, fields, alice,
        )
        assert_eq(response.code, 400)
        assert_true(body.contains("confirm its SSH host fingerprint"))
        assert_true(body.contains("git@source.example:org/demo.git"))
        assert_true(body.contains("name=\"active\" value=\"1\" checked"))
        assert_false(body.contains("realpath"))
        let actor = @identity.active_user_by_name(pool, "alice")
        let repo : @domain.RepoId = { owner: "alice", name: "demo", }
        assert_true(@repository.push_mirrors(pool, actor, repo).is_empty())
      },
      repo_root=root,
    )
  })
}

///|
async test "mirror creation and key rotation work without SSH import or trusted destinations" {
  @test_support.with_git_test_repo((root, _) => {
    @web_testkit.with_ssh_settings_app(
      (port, pool, alice, _, _) => {
        let route = "/alice/demo/settings/mirrors"
        let (_, initial) = @web_testkit.http_get_path_with_cookie(
          port, route, alice,
        )
        assert_false(initial.contains("not configured"))
        let (_, form) = @web_testkit.http_get_path_with_cookie(
          port,
          route + "/new",
          alice,
        )
        let csrf = @web_testkit.extract_attr(
          form, "name=\"csrf_token\"", "value=\"",
        )
        let (invalid, _) = @web_testkit.http_post_path_with_cookie(
          port,
          route,
          "csrf_token=\{csrf}&url=ext%3A%3Ash%20-c%20bad",
          alice,
        )
        assert_eq(invalid.code, 400)
        let (created, _) = @web_testkit.http_post_path_with_cookie(
          port,
          route,
          "csrf_token=\{csrf}&url=git%40source.example%3Aorg%2Fdemo.git",
          alice,
        )
        assert_eq(created.code, 303)
        let actor = @identity.active_user_by_name(pool, "alice")
        let repo : @domain.RepoId = { owner: "alice", name: "demo", }
        let mirror = @repository.push_mirrors(pool, actor, repo)[0]
        assert_false(mirror.active)
        assert_eq(mirror.status, "disabled")
        assert_true(mirror.public_key.has_prefix("ssh-ed25519 "))
        let edit = route + "/" + mirror.id.to_string()
        let (_, details) = @web_testkit.http_get_path_with_cookie(
          port, edit, alice,
        )
        assert_true(details.contains(mirror.public_key))
        assert_false(details.contains("PRIVATE KEY"))
        let (blocked, error) = @web_testkit.http_post_path_with_cookie(
          port,
          edit,
          "csrf_token=\{csrf}&version=1&url=git%40source.example%3Aorg%2Fdemo.git&active=1",
          alice,
        )
        assert_eq(blocked.code, 400)
        assert_true(error.contains("confirm its SSH host fingerprint"))
        assert_true(error.contains(mirror.public_key))
        assert_eq(@repository.push_mirrors(pool, actor, repo)[0].version, 1L)
        let (updated, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit,
          "csrf_token=\{csrf}&version=1&url=git%40new.example%3Aorg%2Fdemo.git",
          alice,
        )
        assert_eq(updated.code, 303)
        let (rotated, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/rotate-key",
          "csrf_token=\{csrf}&version=2",
          alice,
        )
        assert_eq(rotated.code, 303)
        assert_false(
          @repository.push_mirrors(pool, actor, repo)[0].public_key ==
          mirror.public_key,
        )
        assert_false(@fs.exists(root + "/credentials"))
        let (forged, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit,
          "csrf_token=\{csrf}&version=3&url=git%40new.example%3Aorg%2Fdemo.git&active=1&host_keys=ssh-ed25519%20AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB",
          alice,
        )
        assert_eq(forged.code, 400)
        assert_true(
          @repository.push_mirrors(pool, actor, repo)[0].host_keys.is_empty(),
        )
      },
      repo_root=root,
    )
  })
}

///|
async test "repository managers initialize and explicitly confirm a destination before enabling it" {
  @test_support.with_git_test_repo((root, _) => {
    let scanner = root + "/keyscan"
    @fs.write_file(
      scanner,
      "#!/bin/sh\nprintf '%s\\n' 'source.example " +
      @test_support.test_ssh_public_key +
      "'\n",
      permission=0o700,
    )
    @web_testkit.with_ssh_settings_app(
      (port, pool, alice, bob, _) => {
        let route = "/alice/demo/settings/mirrors"
        let (_, form) = @web_testkit.http_get_path_with_cookie(
          port,
          route + "/new",
          alice,
        )
        let csrf = @web_testkit.extract_attr(
          form, "name=\"csrf_token\"", "value=\"",
        )
        let (created, _) = @web_testkit.http_post_path_with_cookie(
          port,
          route,
          "csrf_token=\{csrf}&url=git%40source.example%3Aorg%2Fdemo.git",
          alice,
        )
        assert_eq(created.code, 303)
        let actor = @identity.active_user_by_name(pool, "alice")
        let repo : @domain.RepoId = { owner: "alice", name: "demo", }
        let mirror = @repository.push_mirrors(pool, actor, repo)[0]
        let edit = route + "/" + mirror.id.to_string()
        let (csrf_error, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/initialize-host",
          "version=1",
          alice,
        )
        assert_eq(csrf_error.code, 403)
        let (outsider, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/initialize-host",
          "csrf_token=\{csrf}&version=1",
          bob,
        )
        assert_eq(outsider.code, 404)
        let (initialized, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/initialize-host",
          "csrf_token=\{csrf}&version=1",
          alice,
        )
        assert_eq(initialized.code, 303)
        let (_, confirmation) = @web_testkit.http_get_path_with_cookie(
          port, edit, alice,
        )
        assert_true(confirmation.contains("Trust this host key"))
        assert_true(confirmation.contains("SHA256:"))
        assert_true(confirmation.contains("git@source.example:org/demo.git"))
        assert_false(confirmation.contains("PRIVATE KEY"))
        let pending = @repository.push_mirrors(pool, actor, repo)[0]
        assert_true(pending.host_keys.is_empty())
        assert_false(pending.active)
        let challenge = @web_testkit.extract_attr(
          confirmation, "name=\"challenge\"", "value=\"",
        )
        let (forged, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/confirm-host",
          "csrf_token=\{csrf}&version=1&challenge=forged",
          alice,
        )
        assert_eq(forged.code, 400)
        let (confirmed, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/confirm-host",
          "csrf_token=\{csrf}&version=1&challenge=\{challenge}",
          alice,
        )
        assert_eq(confirmed.code, 303)
        let trusted = @repository.push_mirrors(pool, actor, repo)[0]
        assert_eq(trusted.host_keys, @test_support.test_ssh_public_key)
        assert_eq(trusted.version, 2L)
        assert_false(trusted.active)
        let (replayed, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit + "/confirm-host",
          "csrf_token=\{csrf}&version=1&challenge=\{challenge}",
          alice,
        )
        assert_eq(replayed.code, 400)
        let (enabled, _) = @web_testkit.http_post_path_with_cookie(
          port,
          edit,
          "csrf_token=\{csrf}&version=2&url=git%40source.example%3Aorg%2Fdemo.git&active=1",
          alice,
        )
        assert_eq(enabled.code, 303)
        assert_true(@repository.push_mirrors(pool, actor, repo)[0].active)
        assert_false(@fs.exists(root + "/credentials"))
      },
      repo_root=root,
      mirror_config={
        ..@repository.default_mirror_config,
        keyscan_command: scanner,
      },
    )
  })
}
