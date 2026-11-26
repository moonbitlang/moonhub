///|
async test "site administrators grant access to an existing user from site settings" {
  @web_testkit.with_ssh_settings_app((port, _, alice, bob, admin) => {
    let path = "/-/admin/settings/users"
    let promotion = path + "/2/promote"
    let (settings, sidebar) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/settings/ssh", admin,
    )
    assert_eq(settings.code, 200)
    assert_true(sidebar.contains("href=\"\{path}\""))

    let (lookup, result) = @web_testkit.http_get_path_with_cookie(
      port,
      path + "?username=bob",
      admin,
    )
    assert_eq(lookup.code, 200)
    assert_eq(lookup.headers.get("cache-control"), Some("no-store"))
    assert_true(result.contains("<h2 id=\"site-user-account\">Bob</h2>"))
    assert_true(result.contains("<code>@bob</code>"))
    assert_true(result.contains("action=\"\{promotion}\""))
    assert_true(result.contains("Make site administrator"))
    let csrf = @web_testkit.extract_attr(
      result, "name=\"csrf_token\"", "value=\"",
    )
    let (before, _) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/settings/ssh", bob,
    )
    assert_eq(before.code, 403)

    let (saved, _) = @web_testkit.http_post_path_with_cookie(
      port,
      promotion,
      "csrf_token=\{csrf}",
      admin,
    )
    assert_eq(saved.code, 303)
    let location = saved.headers.get("location").unwrap()
    assert_eq(location, path + "?username=bob&granted=1")
    let (confirmed, body) = @web_testkit.http_get_path_with_cookie(
      port, location, admin,
    )
    assert_eq(confirmed.code, 200)
    assert_true(body.contains("Site administrator access granted."))
    assert_true(body.contains("<code>@bob</code>"))
    assert_true(!body.contains("Make site administrator"))

    let (repeated, _) = @web_testkit.http_post_path_with_cookie(
      port,
      promotion,
      "csrf_token=\{csrf}",
      admin,
    )
    assert_eq(repeated.code, 303)
    let (after, _) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/settings/ssh", bob,
    )
    assert_eq(after.code, 200)
    let (unrelated, _) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/settings/ssh", alice,
    )
    assert_eq(unrelated.code, 403)
  })
}

///|
async test "site administrator grants require the correct session and an active target" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, admin) => {
    let path = "/-/admin/settings/users"
    let promotion = path + "/2/promote"
    let (anonymous, _) = @web_testkit.http_get_path(port, path)
    assert_eq(anonymous.code, 303)
    let (forbidden, _) = @web_testkit.http_get_path_with_cookie(
      port,
      path + "?username=bob",
      alice,
    )
    assert_eq(forbidden.code, 403)
    let alice_csrf = @web_context.form_csrf_token(alice.value, promotion)
    let (denied, _) = @web_testkit.http_post_path_with_cookie(
      port,
      promotion,
      "csrf_token=\{alice_csrf}",
      alice,
    )
    assert_eq(denied.code, 403)

    let (missing, message) = @web_testkit.http_get_path_with_cookie(
      port,
      path + "?username=unknown",
      admin,
    )
    assert_eq(missing.code, 200)
    assert_true(message.contains("No active user found."))
    assert_true(!message.contains("Make site administrator"))
    let (_, other_target) = @web_testkit.http_get_path_with_cookie(
      port,
      path + "?username=alice",
      admin,
    )
    let other_csrf = @web_testkit.extract_attr(
      other_target, "name=\"csrf_token\"", "value=\"",
    )
    let (_, result) = @web_testkit.http_get_path_with_cookie(
      port,
      path + "?username=bob",
      admin,
    )
    let csrf = @web_testkit.extract_attr(
      result, "name=\"csrf_token\"", "value=\"",
    )
    let other_session = pool.with_client(client => {
      client.with_transaction(tx => {
        @web_context.session_cookie(@identity.create_session_token(tx, 3L))
      })
    })
    for
      (token, cookie) in [
        ("", admin),
        (other_csrf, admin),
        (csrf, other_session),
      ] {
      let (rejected, _) = @web_testkit.http_post_path_with_cookie(
        port,
        promotion,
        "csrf_token=\{token}",
        cookie,
      )
      assert_eq(rejected.code, 403)
    }
    assert_true(!@identity.active_user_by_name(pool, "bob").is_site_admin)

    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'disabled' WHERE id = 2",
      )
    })
    let (inactive, _) = @web_testkit.http_post_path_with_cookie(
      port,
      promotion,
      "csrf_token=\{csrf}",
      admin,
    )
    assert_eq(inactive.code, 404)
    let (_, disabled) = @web_testkit.http_get_path_with_cookie(
      port,
      path + "?username=bob",
      admin,
    )
    assert_true(disabled.contains("No active user found."))
    assert_true(!disabled.contains("Make site administrator"))
  })
}
