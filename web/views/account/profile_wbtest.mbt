///|
async test "users change their own display name and never their username" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let (page, body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/settings/profile", alice,
    )
    assert_eq(page.code, 200)
    assert_true(body.contains("value=\"alice\" readonly=\"\""))
    assert_true(body.contains("value=\"Alice\""))
    assert_true(body.contains("cannot be changed"))
    assert_true(body.contains("No email on file."))
    assert_true(body.contains("title=\"Profile\" aria-current=\"page\""))
    let token = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let (saved, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/settings/profile",
      "csrf_token=\{token}&name_key=bob&is_site_admin=1&username=root&display_name=Alice%20Liddell",
      alice,
    )
    assert_eq(saved.code, 303)
    assert_true(
      saved.headers.get("location") is Some("/-/settings/profile?saved=1"),
    )
    let updated = @identity.active_user_by_name(pool, "alice")
    assert_eq(updated.display_name, "Alice Liddell")
    assert_eq(updated.name_key, "alice")
    assert_true(!updated.is_site_admin)
    assert_eq(@identity.active_user_by_name(pool, "bob").display_name, "Bob")
    assert_eq(
      @identity.active_user_by_name(pool, "admin").display_name,
      "Admin",
    )
    assert_eq(
      @identity.get_team_by_name_key(pool, "alice").unwrap().display_name,
      "Alice Liddell",
    )
    let (list, list_body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/teams", alice,
    )
    assert_eq(list.code, 200)
    assert_true(list_body.contains("Alice Liddell"))
    let (_, saved_body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/settings/profile?saved=1", alice,
    )
    assert_true(saved_body.contains("Profile saved."))
    assert_true(saved_body.contains("value=\"Alice Liddell\""))
  })
}

///|
async test "profile updates reject empty oversized or tokenless submissions" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, bob, _) => {
    let token = @web_testkit.profile_form_token(port, alice)
    for
      (body, message) in [
        ("display_name=", "display name is required"),
        ("display_name=%20%20", "display name is required"),
        ("display_name=a%0Ab", "display name cannot contain control characters"),
        (
          "display_name=\{"a".repeat(101)}",
          "display name must be 100 characters or fewer",
        ),
      ] {
      let (response, response_body) = @web_testkit.http_post_path_with_cookie(
        port,
        "/-/settings/profile",
        "csrf_token=\{token}&\{body}",
        alice,
      )
      assert_eq(response.code, 400)
      assert_true(response_body.contains(message), msg=body)
    }
    let foreign = @web_testkit.profile_form_token(port, bob)
    for token in ["", "forged", foreign] {
      let (rejected, _) = @web_testkit.http_post_path_with_cookie(
        port,
        "/-/settings/profile",
        "csrf_token=\{token}&display_name=Taken%20Over",
        alice,
      )
      assert_eq(rejected.code, 403)
    }
    assert_eq(
      @identity.active_user_by_name(pool, "alice").display_name,
      "Alice",
    )
    assert_eq(@identity.active_user_by_name(pool, "bob").display_name, "Bob")
    assert_eq(
      @identity.get_team_by_name_key(pool, "alice").unwrap().display_name,
      "Alice",
    )
  })
}

///|
async test "profile settings require a full active login" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let (anonymous, _) = @web_testkit.http_get_path(port, "/-/settings/profile")
    assert_eq(anonymous.code, 303)
    assert_true(anonymous.headers.get("location") is Some("/-/login"))
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'disabled' WHERE id = 1",
      )
    })
    let (disabled, _) = @web_testkit.http_get_path_with_cookie(
      port, "/-/settings/profile", alice,
    )
    assert_eq(disabled.code, 303)
    assert_true(disabled.headers.get("location") is Some("/-/login"))
  })
}
