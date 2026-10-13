///|
async fn deploy_form_token(
  port : Int32,
  cookie : @http.Cookie,
  repo~ : String = "alice/demo",
) -> String {
  let (response, body) = @web_testkit.http_get_path_with_cookie(
    port,
    "/\{repo}/settings/deploy-keys/new",
    cookie,
  )
  assert_eq(response.code, 200)
  assert_true(response.headers.get("cache-control") is Some("no-store"))
  assert_true(response.headers.get("x-frame-options") is Some("DENY"))
  assert_false(body.contains("value=\"1\" checked"))
  @web_testkit.extract_attr(body, "name=\"csrf_token\"", "value=\"")
}

///|
async test "repository deploy key forms create change permissions and revoke with audit" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let route = "/alice/demo/settings/deploy-keys"
    let token = deploy_form_token(port, alice)
    let (created, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "csrf_token=\{token}&title=Production&public_key=" +
      @test_support.test_ssh_public_key.replace(old=" ", new="%20"),
      alice,
    )
    assert_eq(created.code, 303)
    assert_eq(created.headers.get("location"), Some(route))
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let key = @ssh.repository_deploy_keys(pool, actor, repo)[0]
    assert_false(key.write_access)
    let (listed, body) = @web_testkit.http_get_path_with_cookie(
      port, route, alice,
    )
    assert_eq(listed.code, 200)
    for
      text in [
        "Production",
        key.fingerprint,
        "Read-only",
        "Added by",
        "Never",
        "aria-current=\"page\"",
      ] {
      assert_true(body.contains(text))
    }
    for (value, write) in [("&write_access=1", true), ("", false)] {
      let (saved, _) = @web_testkit.http_post_path_with_cookie(
        port,
        "\{route}/\{key.id}/access",
        "csrf_token=\{token}" + value,
        alice,
      )
      assert_eq(saved.code, 303)
      assert_eq(
        @ssh.repository_deploy_keys(pool, actor, repo)[0].write_access,
        write,
      )
    }
    let (confirmation, _) = @web_testkit.http_get_path_with_cookie(
      port,
      "\{route}/\{key.id}/revoke",
      alice,
    )
    assert_eq(confirmation.code, 200)
    assert_true(
      @ssh.repository_deploy_keys(pool, actor, repo)[0].revoked_at is None,
    )
    let (revoked, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "\{route}/\{key.id}/revoke",
      "csrf_token=\{token}",
      alice,
    )
    assert_eq(revoked.code, 303)
    let (_, body) = @web_testkit.http_get_path_with_cookie(port, route, alice)
    assert_true(body.contains("Revoked"))
    assert_false(body.contains("Edit access for Production"))
    for action in ["access", "revoke"] {
      let (response, _) = @web_testkit.http_post_path_with_cookie(
        port,
        "\{route}/\{key.id}/\{action}",
        "csrf_token=\{token}",
        alice,
      )
      assert_eq(response.code, 404)
    }
  })
}

///|
async test "deploy key HTTP authorization is scoped to manager repository and session" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, bob, admin) => {
    let route = "/alice/demo/settings/deploy-keys"
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let id = @ssh.add_repository_deploy_key(
      pool,
      actor,
      repo,
      "Private title",
      @ssh.parse_ssh_public_key(@test_support.test_ssh_public_key),
    )
    let token = deploy_form_token(port, alice)
    for suffix in ["", "/new", "/\{id}/access", "/\{id}/revoke"] {
      let (anonymous, _) = @web_testkit.http_get_path(port, route + suffix)
      assert_eq(anonymous.code, 303)
      let (other, body) = @web_testkit.http_get_path_with_cookie(
        port,
        route + suffix,
        bob,
      )
      assert_eq(other.code, 404)
      assert_false(body.contains("Private title"))
    }
    for suffix in ["", "/\{id}/access", "/\{id}/revoke"] {
      let (missing_csrf, _) = @web_testkit.http_post_path_with_cookie(
        port,
        route + suffix,
        "",
        alice,
      )
      assert_eq(missing_csrf.code, 403)
      let (other, _) = @web_testkit.http_post_path_with_cookie(
        port,
        route + suffix,
        "csrf_token=\{token}",
        bob,
      )
      assert_eq(other.code, 404)
      let (wrong_session, _) = @web_testkit.http_post_path_with_cookie(
        port,
        route + suffix,
        "csrf_token=\{token}",
        admin,
      )
      assert_eq(wrong_session.code, 403)
    }
    let other_token = deploy_form_token(port, alice, repo="alice/public")
    for action in ["access", "revoke"] {
      let path = "/alice/public/settings/deploy-keys/\{id}/\{action}"
      let (cross_token, _) = @web_testkit.http_post_path_with_cookie(
        port,
        path,
        "csrf_token=\{token}",
        alice,
      )
      assert_eq(cross_token.code, 403)
      let (cross_repo, _) = @web_testkit.http_post_path_with_cookie(
        port,
        path,
        "csrf_token=\{other_token}",
        alice,
      )
      assert_eq(cross_repo.code, 404)
      let (other, _) = @web_testkit.http_get_path_with_cookie(port, path, alice)
      assert_eq(other.code, 404)
    }
    let (public, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/public/settings/deploy-keys", bob,
    )
    assert_eq(public.code, 403)
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
        ),
      )
    })
    let (member_response, _) = @web_testkit.http_get_path_with_cookie(
      port, route, bob,
    )
    assert_eq(member_response.code, 403)
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE team_member SET role = 'admin' WHERE team_id = 1 AND user_id = 2",
        ),
      )
    })
    let bob_token = deploy_form_token(port, bob)
    let (saved, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "\{route}/\{id}/access",
      "csrf_token=\{bob_token}&write_access=1",
      bob,
    )
    assert_eq(saved.code, 303)
    assert_true(@ssh.repository_deploy_keys(pool, actor, repo)[0].write_access)
  })
}

///|
async test "deploy key forms redact private keys escape names and reject invalid modes and collisions" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let token = deploy_form_token(port, alice)
    let route = "/alice/demo/settings/deploy-keys"
    let prefix = "csrf_token=\{token}&title=Production&public_key="
    for
      key in [
        "invalid", "-----BEGIN%20OPENSSH%20PRIVATE%20KEY-----%0Asecret-must-not-leak",
      ] {
      let (response, body) = @web_testkit.http_post_path_with_cookie(
        port,
        route,
        prefix + key,
        alice,
      )
      assert_eq(response.code, 400)
      assert_true(body.contains("value=\"Production\""))
      assert_false(body.contains("secret-must-not-leak"))
    }
    let public_key = @test_support.test_ssh_public_key.replace(
      old=" ",
      new="%20",
    )
    let (mode, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      prefix + public_key + "&write_access=admin",
      alice,
    )
    assert_eq(mode.code, 400)
    let (large, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      "x".repeat(65537),
      alice,
    )
    assert_eq(large.code, 400)
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let cross_site = client.post(route, prefix + public_key, extra_headers={
      "Cookie": "\{alice.name}=\{alice.value}",
      "Sec-Fetch-Site": "cross-site",
      "Content-Type": "application/x-www-form-urlencoded",
    })
    client.skip_response_body()
    assert_eq(cross_site.code, 403)
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    assert_true(@ssh.repository_deploy_keys(pool, actor, repo).is_empty())
    let id = @ssh.add_repository_deploy_key(
      pool,
      actor,
      repo,
      "<img src=x>",
      @ssh.parse_ssh_public_key(@test_support.test_ssh_public_key),
    )
    for suffix in ["", "/\{id}/access", "/\{id}/revoke"] {
      let (_, body) = @web_testkit.http_get_path_with_cookie(
        port,
        route + suffix,
        alice,
      )
      assert_true(body.contains("&lt;img"))
      assert_false(body.contains("<img"))
    }
    let (duplicate, body) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      prefix + public_key,
      alice,
    )
    assert_eq(duplicate.code, 400)
    assert_true(body.contains("already registered"))
    let (bad_mode, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "\{route}/\{id}/access",
      "csrf_token=\{token}&write_access=admin",
      alice,
    )
    assert_eq(bad_mode.code, 400)
    assert_false(@ssh.repository_deploy_keys(pool, actor, repo)[0].write_access)
  })
}
