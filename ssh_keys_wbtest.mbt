///|
async fn with_ssh_settings_app(
  f : async (Int, Database, @http.Cookie, @http.Cookie, @http.Cookie) -> Unit,
  addresses? : SshAddressConfig = no_ssh_address_config,
) -> Unit {
  with_ssh_test_db(pool => {
    let cookies = pool.with_client(client => {
      client.with_transaction(tx => {
        [1L, 2L, 3L].map(id => session_cookie(create_session_token(tx, id)))
      })
    })
    let app = @moonback.App(
      app_module,
      config=Config(custom=[
        @moonback.Config::custom(config_root, test_repo_root),
        @moonback.Config::custom(config_assets_root, test_assets_root),
        @moonback.Config::custom(config_db_pool, pool),
        @moonback.Config::custom(config_ssh_addresses, addresses),
      ]),
    )
    defer app.close()
    @async.with_task_group(group => {
      let listener = @moonback.listen(port=0)
      let task = group.spawn(() => app.serve(listener))
      defer task.cancel()
      f(listener.addr.port(), pool, cookies[0], cookies[1], cookies[2])
    })
  })
}

///|
async fn settings_form_token(port : Int, cookie : @http.Cookie) -> String {
  let (response, body) = http_get_path_with_cookie(
    port, "/settings/ssh-keys/new", cookie,
  )
  assert_eq(response.code, 200)
  assert_true(response.headers.get("cache-control") is Some("no-store"))
  assert_true(response.headers.get("x-frame-options") is Some("DENY"))
  assert_true(!body.contains(cookie.value))
  extract_attr(body, "name=\"csrf_token\"", "value=\"")
}

///|
test "SSH settings CSRF tokens are session-bound and not login credentials" {
  let first = form_csrf_token("first-session", "ssh-key-settings")
  let second = form_csrf_token("second-session", "ssh-key-settings")
  assert_eq(first.length(), 64)
  assert_true(first != second)
  assert_true(first != hash_token("first-session"))
  assert_true(valid_form_token(first, first))
  assert_true(!valid_form_token(first, second))
  assert_true(!valid_form_token(first, ""))
  assert_true(!valid_form_token(first, first + "0"))
  assert_true(!valid_form_token("", ""))
}

///|
async test "users add and revoke their own SSH keys through the web UI" {
  with_ssh_settings_app((port, pool, alice, _, _) => {
    let token = settings_form_token(port, alice)
    let encoded_key = test_ssh_public_key.replace(old=" ", new="%20")
    let (response, _) = http_post_path_with_cookie(
      port,
      "/settings/ssh-keys",
      "csrf_token=\{token}&title=Laptop&public_key=\{encoded_key}&user_id=2&user=bob",
      alice,
    )
    assert_eq(response.code, 303)
    assert_true(response.headers.get("location") is Some("/settings/ssh-keys"))
    let user = active_user_by_name(pool, "alice")
    let keys = user_ssh_keys(pool, user)
    assert_eq(keys.length(), 1)
    assert_eq(keys[0].title, "Laptop")
    assert_eq(user_ssh_keys(pool, active_user_by_name(pool, "bob")).length(), 0)
    let (list, body) = http_get_path_with_cookie(
      port, "/settings/ssh-keys", alice,
    )
    assert_eq(list.code, 200)
    assert_true(body.contains("Laptop"))
    assert_true(body.contains(keys[0].fingerprint))
    assert_true(body.contains("Never"))
    assert_true(body.contains("1 active"))
    let path = "/settings/ssh-keys/\{keys[0].id}/revoke"
    let (confirm, confirm_body) = http_get_path_with_cookie(port, path, alice)
    assert_eq(confirm.code, 200)
    assert_true(confirm_body.contains("Revocation cannot be undone."))
    assert_true(
      authorized_ssh_key(pool, parse_ssh_public_key(test_ssh_public_key))
      is Some(_),
    )
    let csrf = extract_attr(confirm_body, "name=\"csrf_token\"", "value=\"")
    let (revoked, _) = http_post_path_with_cookie(
      port,
      path,
      "csrf_token=\{csrf}",
      alice,
    )
    assert_eq(revoked.code, 303)
    assert_true(
      authorized_ssh_key(pool, parse_ssh_public_key(test_ssh_public_key))
      is None,
    )
    let (_, after) = http_get_path_with_cookie(
      port, "/settings/ssh-keys", alice,
    )
    assert_true(after.contains("0 active"))
    assert_true(after.contains("Revoked"))
    assert_true(!after.contains("aria-label=\"Revoke Laptop\""))
    let (again, _) = http_post_path_with_cookie(
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
  with_ssh_settings_app((port, pool, alice, bob, admin) => {
    let key = parse_ssh_public_key(test_ssh_public_key)
    let id = add_ssh_key(
      pool,
      active_user_by_name(pool, "alice"),
      "Alice private title",
      key,
    )
    let path = "/settings/ssh-keys/\{id}/revoke"
    for cookie in [bob, admin] {
      let token = settings_form_token(port, cookie)
      let (listed, body) = http_get_path_with_cookie(
        port, "/settings/ssh-keys", cookie,
      )
      assert_eq(listed.code, 200)
      assert_true(!body.contains("Alice private title"))
      assert_true(!body.contains(key.fingerprint))
      let (confirmation, _) = http_get_path_with_cookie(port, path, cookie)
      assert_eq(confirmation.code, 404)
      let (denied, _) = http_post_path_with_cookie(
        port,
        path,
        "csrf_token=\{token}",
        cookie,
      )
      assert_eq(denied.code, 404)
    }
    let (allowed, _) = http_get_path_with_cookie(port, path, alice)
    assert_eq(allowed.code, 200)
    assert_true(authorized_ssh_key(pool, key) is Some(_))
  })
}

///|
async test "SSH key mutation rejects missing forged and different-session CSRF tokens" {
  with_ssh_settings_app((port, pool, alice, bob, _) => {
    let other_session = pool.with_client(client => {
      client.with_transaction(tx => session_cookie(create_session_token(tx, 1L)))
    })
    let foreign = settings_form_token(port, bob)
    let stale = settings_form_token(port, other_session)
    let public_key = test_ssh_public_key.replace(old=" ", new="%20")
    for token in ["", "forged", foreign, stale] {
      let (response, _) = http_post_path_with_cookie(
        port,
        "/settings/ssh-keys",
        "csrf_token=\{token}&title=Laptop&public_key=\{public_key}",
        alice,
      )
      assert_eq(response.code, 403)
    }
    assert_eq(
      user_ssh_keys(pool, active_user_by_name(pool, "alice")).length(),
      0,
    )
    let id = add_ssh_key(
      pool,
      active_user_by_name(pool, "alice"),
      "Laptop",
      parse_ssh_public_key(test_ssh_public_key),
    )
    let (response, _) = http_post_path_with_cookie(
      port,
      "/settings/ssh-keys/\{id}/revoke",
      "",
      alice,
    )
    assert_eq(response.code, 403)
    assert_true(
      own_active_ssh_key(pool, active_user_by_name(pool, "alice"), id).revoked_at
      is None,
    )
  })
}

///|
async test "cross-site and oversized requests cannot add SSH keys" {
  with_ssh_settings_app((port, pool, alice, _, _) => {
    let token = settings_form_token(port, alice)
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let response = client.post("/settings/ssh-keys", "csrf_token=\{token}", extra_headers={
      "Cookie": "\{alice.name}=\{alice.value}",
      "Sec-Fetch-Site": "cross-site",
      "Content-Type": "application/x-www-form-urlencoded",
    })
    client.skip_response_body()
    assert_eq(response.code, 403)
    let (large, _) = http_post_path_with_cookie(
      port,
      "/settings/ssh-keys",
      "x".repeat(65537),
      alice,
    )
    assert_eq(large.code, 400)
    assert_eq(
      user_ssh_keys(pool, active_user_by_name(pool, "alice")).length(),
      0,
    )
  })
}

///|
async test "invalid and duplicate keys preserve form names but never echo private keys" {
  with_ssh_settings_app((port, pool, alice, _, _) => {
    let token = settings_form_token(port, alice)
    let prefix = "csrf_token=\{token}&title=Work%20laptop&public_key="
    let (invalid, invalid_body) = http_post_path_with_cookie(
      port,
      "/settings/ssh-keys",
      prefix + "invalid",
      alice,
    )
    assert_eq(invalid.code, 400)
    assert_true(invalid_body.contains("value=\"Work laptop\""))
    assert_true(invalid_body.contains("role=\"alert\""))
    let private_key = "-----BEGIN%20OPENSSH%20PRIVATE%20KEY-----%0Anever-echo-this-secret%0A-----END%20OPENSSH%20PRIVATE%20KEY-----"
    let (private_response, private_body) = http_post_path_with_cookie(
      port,
      "/settings/ssh-keys",
      prefix + private_key,
      alice,
    )
    assert_eq(private_response.code, 400)
    assert_true(!private_body.contains("never-echo-this-secret"))
    assert_true(!private_body.contains("BEGIN OPENSSH PRIVATE KEY"))
    let key = parse_ssh_public_key(test_ssh_public_key)
    let _ = add_ssh_key(
      pool,
      active_user_by_name(pool, "bob"),
      "Not public metadata",
      key,
    )
    let (duplicate, duplicate_body) = http_post_path_with_cookie(
      port,
      "/settings/ssh-keys",
      prefix + test_ssh_public_key.replace(old=" ", new="%20"),
      alice,
    )
    assert_eq(duplicate.code, 400)
    assert_true(duplicate_body.contains("already registered"))
    assert_true(!duplicate_body.contains("Not public metadata"))
    assert_eq(
      user_ssh_keys(pool, active_user_by_name(pool, "alice")).length(),
      0,
    )
  })
}

///|
async test "key names are HTML escaped in lists and revoke confirmation" {
  with_ssh_settings_app((port, pool, alice, _, _) => {
    let id = add_ssh_key(
      pool,
      active_user_by_name(pool, "alice"),
      "<img src=x onerror=alert(1)>",
      parse_ssh_public_key(test_ssh_public_key),
    )
    for path in ["/settings/ssh-keys", "/settings/ssh-keys/\{id}/revoke"] {
      let (response, body) = http_get_path_with_cookie(port, path, alice)
      assert_eq(response.code, 200)
      assert_true(!body.contains("<img"))
      assert_true(body.contains("&lt;img"))
    }
  })
}

///|
async test "SSH key settings require a full active login" {
  with_ssh_settings_app((port, pool, alice, _, _) => {
    for
      path in [
        "/settings/ssh-keys", "/settings/ssh-keys/new", "/settings/ssh-keys/1/revoke",
      ] {
      let (response, _) = http_get_path(port, path)
      assert_eq(response.code, 303)
      assert_true(response.headers.get("location") is Some("/login"))
    }
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'disabled' WHERE id = 1",
      )
    })
    let (disabled, _) = http_get_path_with_cookie(
      port, "/settings/ssh-keys", alice,
    )
    assert_eq(disabled.code, 303)
    assert_true(disabled.headers.get("location") is Some("/login"))
  })
  with_production_test_app((_, port, _) => {
    let invitation = login_test_user(
      port, test_auth_name_key, test_auth_password,
    )
    let (response, _) = http_get_path_with_cookie(
      port, "/settings/ssh-keys/new", invitation,
    )
    assert_eq(response.code, 303)
    assert_true(response.headers.get("location") is Some("/change-password"))
  })
}
