///|
async test "accepting a team invitation also provisions the member's personal namespace" {
  with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO team (id, name_key, display_name, kind) VALUES (3, 'org', 'Org', 'org');
          #|INSERT INTO invitation (id, kind, email, name_key, display_name,
          #|  password_hash, team_id, team_role, invited_by_user_id)
          #|VALUES (9, 'team_member', 'newcomer@example.com', 'newcomer', 'Newcomer',
          #|  'test', 3, 'member', 3);
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
    let org = get_team_by_name_key(pool, "org").unwrap()
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
async test "the teams page lists the signed-in user's personal namespace" {
  with_ssh_settings_app((port, _, alice, bob, _) => {
    let (response, body) = http_get_path_with_cookie(port, "/teams", alice)
    assert_eq(response.code, 200)
    assert_true(body.contains("href=\"/teams/alice\""))
    assert_true(body.contains("<td class=\"muted\">Personal</td>"))
    assert_true(!body.contains("href=\"/teams/bob\""))
    let (_, bob_body) = http_get_path_with_cookie(port, "/teams", bob)
    assert_true(bob_body.contains("href=\"/teams/bob\""))
    assert_true(!bob_body.contains("href=\"/teams/alice\""))
  })
}

///|
async test "users create repositories under their own name from the workspace" {
  with_repository_test_app((port, pool, root, alice, bob) => {
    let (page, body) = http_get_path_with_cookie(port, "/", alice)
    assert_eq(page.code, 200)
    assert_true(body.contains("href=\"/teams/alice/repositories/new\""))
    assert_true(body.contains("New repository"))
    let (_, bob_body) = http_get_path_with_cookie(port, "/", bob)
    assert_true(bob_body.contains("href=\"/teams/bob/repositories/new\""))
    assert_true(!bob_body.contains("href=\"/teams/alice/repositories/new\""))
    let csrf = repository_test_token(port, "alice", alice)
    let (created, _) = http_post_path_with_cookie(
      port,
      "/teams/alice/repositories",
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
