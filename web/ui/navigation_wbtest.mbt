///|
async test "workspace shell selects the team view and keeps private actions authorized" {
  @web_testkit.with_ssh_settings_app((port, _, alice, bob, _) => {
    for tab in ["repositories", "members", "invitations"] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port,
        "/workshop?tab=\{tab}",
        alice,
      )
      assert_eq(response.code, 200)
      assert_true(body.contains("id=\"app-sidebar\""))
      assert_true(body.contains("id=\"main-content\""))
      assert_true(body.contains("/assets/app-shell-"))
      let label = match tab {
        "repositories" => "Team repositories"
        "members" => "Members"
        _ => "Invitations"
      }
      assert_true(body.contains("title=\"\{label}\" aria-current=\"page\""))
      assert_true(!body.contains("aria-label=\"Site settings\""))
      assert_true(!body.contains(alice.value))
    }
    let (bad, _) = @web_testkit.http_get_path_with_cookie(
      port, "/workshop?tab=unknown", alice,
    )
    assert_eq(bad.code, 400)
    let (denied, body) = @web_testkit.http_get_path_with_cookie(
      port, "/workshop?tab=members", bob,
    )
    assert_eq(denied.code, 403)
    assert_true(!body.contains("id=\"team-members\""))
  })
}

///|
async test "repository sidebar matches the current page and hides management for members" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, bob, _) => {
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
      )
    })
    for
      (suffix, label) in [
        ("", "Files"),
        ("/commits", "Commits"),
        ("/issues", "Issues"),
        ("/merge-requests", "Merge requests"),
        ("/settings/branches", "Branch protection"),
      ] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port,
        "/alice/demo\{suffix}",
        alice,
      )
      assert_eq(response.code, 200)
      assert_true(body.contains("title=\"\{label}\" aria-current=\"page\""))
      assert_true(body.contains("href=\"/alice/demo/settings/branches\""))
      assert_true(!body.contains("class=\"tabs\""))
    }
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", bob,
    )
    assert_eq(response.code, 200)
    assert_true(!body.contains("href=\"/alice/demo/settings/branches\""))
  })
}

///|
async test "site administrators reach site settings from every page sidebar" {
  @web_testkit.with_ssh_settings_app((port, _, alice, _, admin) => {
    for
      path in [
        "/", "/-/teams", "/workshop", "/alice/demo", "/-/settings/profile", "/-/settings/ssh-keys",
        "/-/change-password",
      ] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port, path, admin,
      )
      assert_eq(response.code, 200, msg=path)
      assert_true(body.contains("aria-label=\"Site settings\""), msg=path)
      assert_true(
        body.contains("aria-label=\"Site settings\" title=\"Site settings\""),
        msg=path,
      )
      assert_true(
        body.contains(
          "<p class=\"nav-group-label\">Administration</p><a class=\"nav-item\" href=\"/-/admin/settings/ssh\"",
        ),
        msg=path,
      )
    }
    let (settings, settings_body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/settings/ssh", admin,
    )
    assert_eq(settings.code, 200)
    // The site settings scope keeps a single Administration group.
    assert_eq(
      settings_body
      .split("<p class=\"nav-group-label\">Administration</p>")
      .to_array()
      .length(),
      2,
    )
    let (member_page, member_body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", alice,
    )
    assert_eq(member_page.code, 200)
    assert_true(!member_body.contains("aria-label=\"Site settings\""))
    assert_true(!member_body.contains("Administration"))
  })
}

///|
async test "invalid invitation forms retain entered values in the invitations view" {
  @web_testkit.with_ssh_settings_app((port, _, alice, _, _) => {
    let (response, body) = @web_testkit.http_post_path_with_cookie(
      port, "/workshop/-/invitations", "email=guest@example.com&name_key=INVALID&display_name=%3CGuest%3E&role=admin",
      alice,
    )
    assert_eq(response.code, 400)
    assert_true(body.contains("title=\"Invitations\" aria-current=\"page\""))
    assert_true(body.contains("value=\"guest@example.com\""))
    assert_true(body.contains("value=\"INVALID\""))
    assert_true(body.contains("value=\"&lt;Guest&gt;\""))
    assert_true(body.contains("value=\"admin\" selected"))
    assert_true(body.contains("role=\"alert\""))
    let (missing, missing_body) = @web_testkit.http_post_path_with_cookie(
      port, "/workshop/-/invitations", "email=guest@example.com&name_key=guest&role=member",
      alice,
    )
    assert_eq(missing.code, 400)
    assert_true(missing_body.contains("value=\"guest@example.com\""))
    assert_true(missing_body.contains("missing display name"))
  })
}

///|
async test "successful invitation submission returns to its list with distinct acceptance and delivery states" {
  @web_testkit.with_ssh_settings_app((port, _, alice, _, _) => {
    let (response, _) = @web_testkit.http_post_path_with_cookie(
      port, "/workshop/-/invitations", "email=guest@example.com&name_key=guest&display_name=Guest",
      alice,
    )
    assert_eq(response.code, 303)
    assert_true(
      response.headers.get("location")
      is Some("/workshop?tab=invitations&notice=invited"),
    )
    let (page, body) = @web_testkit.http_get_path_with_cookie(
      port, "/workshop?tab=invitations&notice=invited", alice,
    )
    assert_eq(page.code, 200)
    assert_true(body.contains("Invitation created."))
    assert_true(body.contains("data-status=\"sent\">Awaiting acceptance"))
    assert_true(body.contains("data-delivery=\"pending\">Queued"))
  })
}
