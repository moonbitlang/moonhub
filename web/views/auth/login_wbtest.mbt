///|
async test "HTTP login accepts usernames and emails and preserves only the identifier on failure" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, _) => {
    let password = "LoginPassword123"
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET email = 'alice+work@example.com', password_hash = ? WHERE id = 1",
        params=[@identity.hash_password(password)],
      )
    })
    let (response, body) = @web_testkit.http_get_path(port, "/-/login")
    assert_eq(response.code, 200)
    assert_true(body.contains("Username or email"))
    assert_true(body.contains("autocomplete=\"username\""))
    for identifier in ["alice", "%20ALICE%2BWORK%40EXAMPLE.COM%20"] {
      let cookie = @web_testkit.login_test_user(port, identifier, password)
      assert_eq(
        @identity.lookup_session_user(pool, cookie.value).unwrap().name_key,
        "alice",
      )
    }
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let response = client.post(
      "/-/login",
      "name_key=alice%2Bwork%40example.com&password=wrong",
      extra_headers={ "Content-Type": "application/x-www-form-urlencoded" },
    )
    let body = client.read_all().text()
    assert_eq(response.code, 401)
    assert_true(body.contains("Invalid username, email, or password."))
    assert_true(body.contains("role=\"alert\""))
    assert_true(body.contains("value=\"alice+work@example.com\""))
    assert_true(!body.contains("wrong"))
    assert_true(response.cookies.is_empty())
    let response = client.post(
      "/-/login",
      "name_key=%22%3E%3Cscript%3E&password=wrong",
      extra_headers={ "Content-Type": "application/x-www-form-urlencoded" },
    )
    let body = client.read_all().text()
    assert_eq(response.code, 401)
    assert_true(!body.contains("value=\"\"><script>"))
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'disabled' WHERE id = 1",
      )
    })
    let response = client.post(
      "/-/login",
      "name_key=alice%2Bwork%40example.com&password=\{password}",
      extra_headers={ "Content-Type": "application/x-www-form-urlencoded" },
    )
    let body = client.read_all().text()
    assert_eq(response.code, 401)
    assert_true(body.contains("Invalid username, email, or password."))
    assert_true(!body.contains("disabled"))
  })
}

///|
async test "HTTP email login for invitations still requires activation" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, _) => {
    let password = "InvitationPassword123"
    pool.with_client(client => {
      let _ = client.execute(
        (
          #|INSERT INTO invitation (id, kind, email, name_key, display_name,
          #|  password_hash, team_id, team_role, invited_by_user_id)
          #|VALUES (41, 'team_member', 'guest@example.com', 'guest', 'Guest', ?, 3, 'member', 3)
        ),
        params=[@identity.hash_password(password)],
      )
    })
    let cookie = @web_testkit.login_test_user(
      port, "GUEST%40EXAMPLE.COM", password,
    )
    assert_eq(
      @identity.lookup_invitation_session(pool, cookie.value).unwrap().id,
      41L,
    )
    assert_true(@identity.lookup_session_user(pool, cookie.value) is None)
    let (response, _) = @web_testkit.http_get_path_with_cookie(
      port, "/", cookie,
    )
    assert_eq(response.code, 303)
    assert_true(response.headers.get("location") is Some("/-/change-password"))
    let (response, _) = @web_testkit.http_post_path_with_cookie(
      port, "/-/change-password", "new_password=PermanentPassword123&confirm_password=PermanentPassword123",
      cookie,
    )
    assert_eq(response.code, 303)
    let permanent = @web_testkit.login_test_user(
      port, "guest%40example.com", "PermanentPassword123",
    )
    assert_eq(
      @identity.lookup_session_user(pool, permanent.value).unwrap().name_key,
      "guest",
    )
    assert_true(@identity.lookup_invitation_session(pool, cookie.value) is None)
  })
}
