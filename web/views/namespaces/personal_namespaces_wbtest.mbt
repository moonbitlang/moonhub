///|
async test "a personal namespace is not a team anywhere in the product" {
  @web_testkit.with_ssh_settings_app((port, _, alice, bob, admin) => {
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/teams", alice,
    )
    assert_eq(response.code, 200)
    // The directory lists organization teams only.
    assert_true(body.contains("href=\"/workshop\""))
    assert_true(!body.contains("href=\"/alice\""))
    assert_true(!body.contains(">Personal</td>"))
    let (bob_page, bob_body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/teams", bob,
    )
    assert_eq(bob_page.code, 200)
    assert_true(bob_body.contains("href=\"/squad\""))
    assert_true(!bob_body.contains("href=\"/workshop\""))
    // Team membership stays private to its members.
    let (outside, _) = @web_testkit.http_get_path_with_cookie(
      port, "/workshop", bob,
    )
    assert_eq(outside.code, 403)
    // The namespace home lists repositories and no team management.
    let (home, home_body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice", alice,
    )
    assert_eq(home.code, 200)
    assert_true(home_body.contains(">Repositories</h2>"))
    assert_true(!home_body.contains(">Members<"))
    assert_true(!home_body.contains(">Invitations<"))
    assert_true(!home_body.contains("Invite member"))
    assert_true(!home_body.contains("aria-label=\"Team\""))
    // A visitor reads the same namespace without management actions.
    let (visitor, visitor_body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice", bob,
    )
    assert_eq(visitor.code, 200)
    assert_true(!visitor_body.contains("/alice/-/repositories/new"))
    // An organization team keeps its member and invitation views.
    let (team_page, team_body) = @web_testkit.http_get_path_with_cookie(
      port, "/workshop?tab=members", alice,
    )
    assert_eq(team_page.code, 200)
    assert_true(team_body.contains(">Members<"))
    // Personal namespaces expose no team management endpoints.
    for
      path in [
        "/alice/-/invitations", "/alice/-/invitations/1/revoke", "/alice/-/invitations/1/resend",
      ] {
      let (denied, _) = @web_testkit.http_post_path_with_cookie(
        port, path, "email=guest@example.com&name_key=guest&display_name=Guest",
        alice,
      )
      assert_eq(denied.code, 404, msg=path)
    }
    let (credentials, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/-/invitations/1/credentials",
      "csrf_token=\{@web_context.form_csrf_token(admin.value, "invitation-credentials:1")}",
      admin,
    )
    assert_eq(credentials.code, 404)
    // The same endpoints keep working for an organization team.
    let (org_invite, _) = @web_testkit.http_post_path_with_cookie(
      port, "/workshop/-/invitations", "email=guest@example.com&name_key=guest&display_name=Guest&role=member",
      alice,
    )
    assert_eq(org_invite.code, 303)
  })
}
