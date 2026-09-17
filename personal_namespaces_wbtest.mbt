///|
async test "accepting a team invitation also provisions the member's personal namespace" {
  with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO team (id, name_key, display_name, kind) VALUES (5, 'acme', 'Acme', 'org');
          #|INSERT INTO invitation (id, kind, email, name_key, display_name,
          #|  password_hash, team_id, team_role, invited_by_user_id)
          #|VALUES (9, 'team_member', 'newcomer@example.com', 'newcomer', 'Newcomer',
          #|  'test', 5, 'member', 3);
        ),
      )
    })
    let invitation : InvitationSession = {
      id: 9L,
      name_key: "newcomer",
      display_name: "Newcomer",
    }
    guard accept_invitation(pool, invitation, "AcceptedPassword123") is Some(_) else {
      fail("invitation was not accepted")
    }
    let newcomer = active_user_by_name(pool, "newcomer")
    let personal = personal_namespace(pool, newcomer).unwrap_or_else(() => {
      fail("member has no personal namespace")
    })
    assert_eq(personal.kind, "personal")
    assert_eq(personal.name_key, "newcomer")
    assert_eq(personal.display_name, "Newcomer")
    assert_eq(team_role(pool, newcomer, personal.id), Some("owner"))
    let org = get_team_by_name_key(pool, "acme").unwrap()
    assert_eq(team_role(pool, newcomer, org.id), Some("member"))
  })
}

///|
async test "the personal namespace migration backfills existing accounts and keeps foreign names" {
  with_ssh_test_db(pool => {
    let migration = @fs.read_file("db/migrations/006_personal_namespaces.sql").text()
    pool.with_client(client => {
      let _ = client.execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash)
          #|VALUES (9, 'legacy', 'Legacy', 'test')
        ),
      )
      // A user whose name_key is already an organization keeps that namespace.
      let _ = client.execute(
        (
          #|INSERT INTO team (id, name_key, display_name, kind)
          #|VALUES (7, 'shared', 'Shared', 'org')
        ),
      )
      let _ = client.execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash)
          #|VALUES (10, 'shared', 'Shared Member', 'test')
        ),
      )
      // The migration must be replayable without duplicating namespaces.
      client.batch_execute(migration)
      client.batch_execute(migration)
    })
    let legacy = active_user_by_name(pool, "legacy")
    let personal = personal_namespace(pool, legacy).unwrap_or_else(() => {
      fail("existing account has no personal namespace")
    })
    assert_eq(personal.name_key, "legacy")
    assert_eq(personal.display_name, "Legacy")
    assert_eq(team_role(pool, legacy, personal.id), Some("owner"))
    assert_true(
      personal_namespace(pool, active_user_by_name(pool, "shared")) is None,
    )
    let shared = get_team_by_name_key(pool, "shared").unwrap()
    assert_eq(shared.kind, "org")
    assert_eq(shared.display_name, "Shared")
    pool.with_client(client => {
      assert_eq(
        client
        .query_all("SELECT id FROM team WHERE name_key = 'legacy'")
        .length(),
        1,
      )
      assert_eq(
        client
        .query_all("SELECT id FROM team WHERE name_key = 'alice'")
        .length(),
        1,
      )
      assert_eq(
        client
        .query_all("SELECT team_id FROM team_member WHERE user_id = 9")
        .length(),
        1,
      )
      assert_true(
        client.query_opt("SELECT team_id FROM team_member WHERE user_id = 10")
        is None,
      )
    })
  })
}

///|
async test "a personal namespace is not a team anywhere in the product" {
  with_ssh_settings_app((port, _, alice, bob, admin) => {
    let (response, body) = http_get_path_with_cookie(port, "/-/teams", alice)
    assert_eq(response.code, 200)
    // The directory lists organization teams only.
    assert_true(body.contains("href=\"/workshop\""))
    assert_true(!body.contains("href=\"/alice\""))
    assert_true(!body.contains(">Personal</td>"))
    let (bob_page, bob_body) = http_get_path_with_cookie(port, "/-/teams", bob)
    assert_eq(bob_page.code, 200)
    assert_true(bob_body.contains("href=\"/squad\""))
    assert_true(!bob_body.contains("href=\"/workshop\""))
    // Team membership stays private to its members.
    let (outside, _) = http_get_path_with_cookie(port, "/workshop", bob)
    assert_eq(outside.code, 403)
    // The namespace home lists repositories and no team management.
    let (home, home_body) = http_get_path_with_cookie(port, "/alice", alice)
    assert_eq(home.code, 200)
    assert_true(home_body.contains(">Repositories</h2>"))
    assert_true(!home_body.contains(">Members<"))
    assert_true(!home_body.contains(">Invitations<"))
    assert_true(!home_body.contains("Invite member"))
    assert_true(!home_body.contains("aria-label=\"Team\""))
    // A visitor reads the same namespace without management actions.
    let (visitor, visitor_body) = http_get_path_with_cookie(port, "/alice", bob)
    assert_eq(visitor.code, 200)
    assert_true(!visitor_body.contains("/alice/-/repositories/new"))
    // An organization team keeps its member and invitation views.
    let (team_page, team_body) = http_get_path_with_cookie(
      port, "/workshop?tab=members", alice,
    )
    assert_eq(team_page.code, 200)
    assert_true(team_body.contains(">Members<"))
    // Personal namespaces expose no team management endpoints.
    for
      path in [
        "/alice/-/invitations", "/alice/-/invitations/1/revoke", "/alice/-/invitations/1/resend",
      ] {
      let (denied, _) = http_post_path_with_cookie(
        port, path, "email=guest@example.com&name_key=guest&display_name=Guest",
        alice,
      )
      assert_eq(denied.code, 404, msg=path)
    }
    let (credentials, _) = http_post_path_with_cookie(
      port,
      "/alice/-/invitations/1/credentials",
      "csrf_token=\{form_csrf_token(admin.value, "invitation-credentials:1")}",
      admin,
    )
    assert_eq(credentials.code, 404)
    // The same endpoints keep working for an organization team.
    let (org_invite, _) = http_post_path_with_cookie(
      port, "/workshop/-/invitations", "email=guest@example.com&name_key=guest&display_name=Guest&role=member",
      alice,
    )
    assert_eq(org_invite.code, 303)
  })
}

///|
async test "users create repositories under their own name from the workspace" {
  with_repository_test_app((port, pool, root, alice, bob) => {
    let (page, body) = http_get_path_with_cookie(port, "/", alice)
    assert_eq(page.code, 200)
    assert_true(body.contains("href=\"/alice/-/repositories/new\""))
    assert_true(body.contains("New repository"))
    let (_, bob_body) = http_get_path_with_cookie(port, "/", bob)
    assert_true(bob_body.contains("href=\"/bob/-/repositories/new\""))
    assert_true(!bob_body.contains("href=\"/alice/-/repositories/new\""))
    let csrf = repository_test_token(port, "alice", alice)
    let (created, _) = http_post_path_with_cookie(
      port,
      "/alice/-/repositories",
      "csrf_token=\{csrf}&name=notes&visibility=private",
      alice,
    )
    assert_eq(created.code, 303)
    assert_true(run_next_repository_job(pool, root, None))
    let owner = active_user_by_name(pool, "alice")
    let personal = personal_namespace(pool, owner).unwrap_or_else(() => {
      fail("owner has no personal namespace")
    })
    assert_eq(
      require_repository_job(pool, personal, "notes").status,
      "succeeded",
    )
    assert_true(
      can_access_repository(
        pool,
        owner,
        { owner: "alice", name: "notes", },
        Write,
      ),
    )
    let (repo_page, _) = http_get_path_with_cookie(port, "/alice/notes", alice)
    assert_eq(repo_page.code, 200)
    let (outsider, _) = http_get_path_with_cookie(port, "/alice/notes", bob)
    assert_eq(outsider.code, 404)
  })
}
