///|
async test "anonymous password recovery works end to end without authenticating the reset session" {
  @web_testkit.with_ssh_settings_app((port, pool, alice_cookie, bob_cookie, _) => {
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET email = 'alice@example.com' WHERE id = 1",
      )
    })
    let (_, login_page) = @web_testkit.http_get_path(port, "/-/login")
    assert_true(login_page.contains("href=\"/-/forgot-password\""))
    let (page, body) = @web_testkit.http_get_path(port, "/-/forgot-password")
    assert_eq(page.code, 200)
    assert_true(page.headers.get("cache-control") is Some("no-store"))
    assert_true(page.headers.get("referrer-policy") is Some("no-referrer"))
    let cookie = page.cookies[0]
    assert_eq(cookie.name, recovery_cookie_name)
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    assert_true(!body.contains(cookie.value))
    let (requested, body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/forgot-password",
      "email=ALICE%40EXAMPLE.COM&csrf_token=\{csrf}",
      cookie,
    )
    assert_eq(requested.code, 200)
    assert_true(body.contains("If an active account matches that email"))
    assert_true(body.contains("value=\"alice@example.com\""))
    let code = pool.with_client(client => {
      let body : String = client
        .query_one("SELECT body FROM email_outbox")
        .get_name("body")
      let start = body.find("Reset code: ").unwrap() + "Reset code: ".length()
      body[start:start + 32].to_owned()
    })
    assert_true(!body.contains(code))
    let (private_page, _) = @web_testkit.http_get_path_with_cookie(
      port, "/", cookie,
    )
    assert_eq(private_page.code, 303)
    assert_true(private_page.headers.get("location") is Some("/-/login"))
    let (invalid, body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/reset-password",
      "email=alice%40example.com&code=\{code}&new_password=NewPassword123&confirm_password=DifferentPassword123&csrf_token=\{csrf}",
      cookie,
    )
    assert_eq(invalid.code, 400)
    assert_true(body.contains("New passwords do not match."))
    assert_true(body.contains("value=\"\{code}\""))
    assert_true(!body.contains("NewPassword123"))
    assert_true(
      @identity.lookup_session_user(pool, alice_cookie.value) is Some(_),
    )
    let payload = "email=alice%40example.com&code=\{code}&new_password=NewPassword123&confirm_password=NewPassword123&csrf_token=\{csrf}"
    let (reset, body) = @web_testkit.http_post_path_with_cookie(
      port, "/-/reset-password", payload, cookie,
    )
    assert_eq(reset.code, 200)
    assert_true(reset.headers.get("cache-control") is Some("no-store"))
    assert_true(body.contains("Your password has been reset."))
    assert_true(!body.contains(code) && !body.contains("NewPassword123"))
    assert_true(reset.cookies.iter().all(cookie => cookie.value.is_empty()))
    assert_true(@identity.lookup_session_user(pool, alice_cookie.value) is None)
    assert_true(
      @identity.lookup_session_user(pool, bob_cookie.value) is Some(_),
    )
    let signed_in = @web_testkit.login_test_user(
      port, "alice", "NewPassword123",
    )
    assert_eq(
      @identity.lookup_session_user(pool, signed_in.value).unwrap().name_key,
      "alice",
    )
    let (replayed, body) = @web_testkit.http_post_path_with_cookie(
      port, "/-/reset-password", payload, cookie,
    )
    assert_eq(replayed.code, 400)
    assert_true(body.contains("Invalid or expired reset code."))
  })
}

///|
async test "recovery pages remain public for invitation sessions and reject unprotected posts" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, _) => {
    let invitation_cookie = pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO invitation (id, kind, email, name_key, display_name, password_hash, is_site_admin) VALUES (44, 'root', 'pending@example.com', 'pending', 'Pending', 'test', 1)",
      )
      client.with_transaction(tx => {
        @web_context.session_cookie(
          @identity.create_invitation_session_token(tx, 44L),
        )
      })
    })
    for path in ["/-/forgot-password", "/-/reset-password"] {
      let (response, _) = @web_testkit.http_get_path_with_cookie(
        port, path, invitation_cookie,
      )
      assert_eq(response.code, 200)
      let client = @http.Client("http://127.0.0.1:\{port}")
      defer client.close()
      let response = client.post(path, "email=alice%40example.com", extra_headers={
        "Content-Type": "application/x-www-form-urlencoded",
      })
      client.skip_response_body()
      assert_eq(response.code, 403)
    }
    let (response, body) = @web_testkit.http_get_path(
      port, "/-/forgot-password",
    )
    let cookie = response.cookies[0]
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    for path in ["/-/forgot-password", "/-/reset-password"] {
      let (response, _) = @web_testkit.http_post_path_with_cookie(
        port, path, "email=alice%40example.com&csrf_token=wrong", cookie,
      )
      assert_eq(response.code, 403)
      let client = @http.Client("http://127.0.0.1:\{port}")
      defer client.close()
      let response = client.post(
        path,
        "email=alice%40example.com&csrf_token=\{csrf}",
        extra_headers={
          "Cookie": "\{cookie.name}=\{cookie.value}",
          "Content-Type": "application/x-www-form-urlencoded",
          "Sec-Fetch-Site": "cross-site",
        },
      )
      client.skip_response_body()
      assert_eq(response.code, 403)
    }
    pool.with_client(client => {
      assert_true(client.query_all("SELECT id FROM password_reset").is_empty())
    })
  })
}

///|
async test "recovery responses do not disclose account existence and invalid forms preserve safe input" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, _) => {
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET email = 'alice@example.com' WHERE id = 1",
      )
    })
    let (response, body) = @web_testkit.http_get_path(
      port, "/-/forgot-password",
    )
    let cookie = response.cookies[0]
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let (response, unknown) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/forgot-password",
      "email=unknown%40example.com&csrf_token=\{csrf}",
      cookie,
    )
    assert_eq(response.code, 200)
    let (response, known) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/forgot-password",
      "email=alice%40example.com&csrf_token=\{csrf}",
      cookie,
    )
    assert_eq(response.code, 200)
    assert_eq(
      known.replace(old="alice@example.com", new="unknown@example.com"),
      unknown,
    )
    let (response, throttled) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/forgot-password",
      "email=alice%40example.com&csrf_token=\{csrf}",
      cookie,
    )
    assert_eq(response.code, 200)
    assert_eq(throttled, known)
    let (response, body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/forgot-password",
      "email=%22%3E%3Cscript%3E&csrf_token=\{csrf}",
      cookie,
    )
    assert_eq(response.code, 400)
    assert_true(body.contains("Enter a valid email address."))
    assert_true(!body.contains("value=\"\"><script>"))
    for password in ["short", "a".repeat(73)] {
      let (response, body) = @web_testkit.http_post_path_with_cookie(
        port,
        "/-/reset-password",
        "email=alice%40example.com&code=invalid&new_password=\{password}&confirm_password=\{password}&csrf_token=\{csrf}",
        cookie,
      )
      assert_eq(response.code, 400)
      assert_true(body.contains("New password must be"))
    }
    pool.with_client(client => {
      assert_eq(client.query_all("SELECT id FROM password_reset").length(), 1)
      assert_eq(
        (
          client
          .query_one("SELECT password_hash FROM \"user\" WHERE id = 1")
          .get_name("password_hash") : String),
        "test",
      )
    })
  })
}
