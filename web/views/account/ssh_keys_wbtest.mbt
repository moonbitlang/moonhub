///|
async test "users add and revoke their own SSH keys through the web UI" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let token = @web_testkit.settings_form_token(port, alice)
    let encoded_key = @test_support.test_ssh_public_key.replace(
      old=" ",
      new="%20",
    )
    let (response, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/settings/ssh-keys",
      "csrf_token=\{token}&title=Laptop&public_key=\{encoded_key}&user_id=2&user=bob",
      alice,
    )
    assert_eq(response.code, 303)
    assert_true(
      response.headers.get("location") is Some("/-/settings/ssh-keys"),
    )
    let user = @identity.active_user_by_name(pool, "alice")
    let keys = @ssh.user_ssh_keys(pool, user)
    assert_eq(keys.length(), 1)
    assert_eq(keys[0].title, "Laptop")
    assert_eq(
      @ssh.user_ssh_keys(pool, @identity.active_user_by_name(pool, "bob")).length(),
      0,
    )
    let (list, body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/settings/ssh-keys", alice,
    )
    assert_eq(list.code, 200)
    assert_true(body.contains("Laptop"))
    assert_true(body.contains(keys[0].fingerprint))
    assert_true(body.contains("Never"))
    assert_true(body.contains("1 active"))
    let path = "/-/settings/ssh-keys/\{keys[0].id}/revoke"
    let (confirm, confirm_body) = @web_testkit.http_get_path_with_cookie(
      port, path, alice,
    )
    assert_eq(confirm.code, 200)
    assert_true(confirm_body.contains("Revocation cannot be undone."))
    assert_true(
      @ssh.authorized_ssh_key(
        pool,
        @ssh.parse_ssh_public_key(@test_support.test_ssh_public_key),
      )
      is Some(_),
    )
    let csrf = @web_testkit.extract_attr(
      confirm_body, "name=\"csrf_token\"", "value=\"",
    )
    let (revoked, _) = @web_testkit.http_post_path_with_cookie(
      port,
      path,
      "csrf_token=\{csrf}",
      alice,
    )
    assert_eq(revoked.code, 303)
    assert_true(
      @ssh.authorized_ssh_key(
        pool,
        @ssh.parse_ssh_public_key(@test_support.test_ssh_public_key),
      )
      is None,
    )
    let (_, after) = @web_testkit.http_get_path_with_cookie(
      port, "/-/settings/ssh-keys", alice,
    )
    assert_true(after.contains("0 active"))
    assert_true(after.contains("Revoked"))
    assert_true(!after.contains("aria-label=\"Revoke Laptop\""))
    let (again, _) = @web_testkit.http_post_path_with_cookie(
      port,
      path,
      "csrf_token=\{csrf}",
      alice,
    )
    assert_eq(again.code, 404)
  })
}

///|
async test "neither another user nor a site administrator can manage someone else's keys" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, bob, admin) => {
    let key = @ssh.parse_ssh_public_key(@test_support.test_ssh_public_key)
    let id = @ssh.add_ssh_key(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      "Alice private title",
      key,
    )
    let path = "/-/settings/ssh-keys/\{id}/revoke"
    for cookie in [bob, admin] {
      let token = @web_testkit.settings_form_token(port, cookie)
      let (listed, body) = @web_testkit.http_get_path_with_cookie(
        port, "/-/settings/ssh-keys", cookie,
      )
      assert_eq(listed.code, 200)
      assert_true(!body.contains("Alice private title"))
      assert_true(!body.contains(key.fingerprint))
      let (confirmation, _) = @web_testkit.http_get_path_with_cookie(
        port, path, cookie,
      )
      assert_eq(confirmation.code, 404)
      let (denied, _) = @web_testkit.http_post_path_with_cookie(
        port,
        path,
        "csrf_token=\{token}",
        cookie,
      )
      assert_eq(denied.code, 404)
    }
    let (allowed, _) = @web_testkit.http_get_path_with_cookie(port, path, alice)
    assert_eq(allowed.code, 200)
    assert_true(@ssh.authorized_ssh_key(pool, key) is Some(_))
  })
}

///|
async test "SSH key mutation rejects missing forged and different-session CSRF tokens" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, bob, _) => {
    let other_session = pool.with_client(client => {
      client.with_transaction(tx => {
        @web_context.session_cookie(@identity.create_session_token(tx, 1L))
      })
    })
    let foreign = @web_testkit.settings_form_token(port, bob)
    let stale = @web_testkit.settings_form_token(port, other_session)
    let public_key = @test_support.test_ssh_public_key.replace(
      old=" ",
      new="%20",
    )
    for token in ["", "forged", foreign, stale] {
      let (response, _) = @web_testkit.http_post_path_with_cookie(
        port,
        "/-/settings/ssh-keys",
        "csrf_token=\{token}&title=Laptop&public_key=\{public_key}",
        alice,
      )
      assert_eq(response.code, 403)
    }
    assert_eq(
      @ssh.user_ssh_keys(pool, @identity.active_user_by_name(pool, "alice")).length(),
      0,
    )
    let id = @ssh.add_ssh_key(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      "Laptop",
      @ssh.parse_ssh_public_key(@test_support.test_ssh_public_key),
    )
    let (response, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/settings/ssh-keys/\{id}/revoke",
      "",
      alice,
    )
    assert_eq(response.code, 403)
    assert_true(
      @ssh.own_active_ssh_key(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        id,
      ).revoked_at
      is None,
    )
  })
}

///|
async test "cross-site and oversized requests cannot add SSH keys" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let token = @web_testkit.settings_form_token(port, alice)
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let response = client.post("/-/settings/ssh-keys", "csrf_token=\{token}", extra_headers={
      "Cookie": "\{alice.name}=\{alice.value}",
      "Sec-Fetch-Site": "cross-site",
      "Content-Type": "application/x-www-form-urlencoded",
    })
    client.skip_response_body()
    assert_eq(response.code, 403)
    let (large, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/settings/ssh-keys",
      "x".repeat(65537),
      alice,
    )
    assert_eq(large.code, 400)
    assert_eq(
      @ssh.user_ssh_keys(pool, @identity.active_user_by_name(pool, "alice")).length(),
      0,
    )
  })
}

///|
async test "invalid and duplicate keys preserve form names but never echo private keys" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let token = @web_testkit.settings_form_token(port, alice)
    let prefix = "csrf_token=\{token}&title=Work%20laptop&public_key="
    let (invalid, invalid_body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/settings/ssh-keys",
      prefix + "invalid",
      alice,
    )
    assert_eq(invalid.code, 400)
    assert_true(invalid_body.contains("value=\"Work laptop\""))
    assert_true(invalid_body.contains("role=\"alert\""))
    let private_key = "-----BEGIN%20OPENSSH%20PRIVATE%20KEY-----%0Anever-echo-this-secret%0A-----END%20OPENSSH%20PRIVATE%20KEY-----"
    let (private_response, private_body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/settings/ssh-keys",
      prefix + private_key,
      alice,
    )
    assert_eq(private_response.code, 400)
    assert_true(!private_body.contains("never-echo-this-secret"))
    assert_true(!private_body.contains("BEGIN OPENSSH PRIVATE KEY"))
    let key = @ssh.parse_ssh_public_key(@test_support.test_ssh_public_key)
    let _ = @ssh.add_ssh_key(
      pool,
      @identity.active_user_by_name(pool, "bob"),
      "Not public metadata",
      key,
    )
    let (duplicate, duplicate_body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/settings/ssh-keys",
      prefix + @test_support.test_ssh_public_key.replace(old=" ", new="%20"),
      alice,
    )
    assert_eq(duplicate.code, 400)
    assert_true(duplicate_body.contains("already registered"))
    assert_true(!duplicate_body.contains("Not public metadata"))
    assert_eq(
      @ssh.user_ssh_keys(pool, @identity.active_user_by_name(pool, "alice")).length(),
      0,
    )
  })
}

///|
async test "key names are HTML escaped in lists and revoke confirmation" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let id = @ssh.add_ssh_key(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      "<img src=x onerror=alert(1)>",
      @ssh.parse_ssh_public_key(@test_support.test_ssh_public_key),
    )
    for path in ["/-/settings/ssh-keys", "/-/settings/ssh-keys/\{id}/revoke"] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port, path, alice,
      )
      assert_eq(response.code, 200)
      assert_true(!body.contains("<img"))
      assert_true(body.contains("&lt;img"))
    }
  })
}

///|
async test "SSH key settings require a full active login" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    for
      path in [
        "/-/settings/ssh-keys", "/-/settings/ssh-keys/new", "/-/settings/ssh-keys/1/revoke",
      ] {
      let (response, _) = @web_testkit.http_get_path(port, path)
      assert_eq(response.code, 303)
      assert_true(response.headers.get("location") is Some("/-/login"))
    }
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'disabled' WHERE id = 1",
      )
    })
    let (disabled, _) = @web_testkit.http_get_path_with_cookie(
      port, "/-/settings/ssh-keys", alice,
    )
    assert_eq(disabled.code, 303)
    assert_true(disabled.headers.get("location") is Some("/-/login"))
  })
  @web_testkit.with_production_test_app((_, port, _) => {
    let invitation = @web_testkit.login_test_user(
      port, @web_testkit.test_auth_name_key, @web_testkit.test_auth_password,
    )
    let (response, _) = @web_testkit.http_get_path_with_cookie(
      port, "/-/settings/ssh-keys/new", invitation,
    )
    assert_eq(response.code, 303)
    assert_true(response.headers.get("location") is Some("/-/change-password"))
  })
}
