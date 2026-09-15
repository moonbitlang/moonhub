///|
async test "team invitations accepted out of order reference the correct users" {
  with_ssh_settings_app((port, pool, _, _, _) => {
    let password = "InvitationPassword123"
    let password_hash = hash_password(password)
    pool.with_client(client => {
      let _ = client.execute(
        (
          #|INSERT INTO invitation (id, kind, email, name_key, display_name,
          #|  password_hash, team_id, team_role, invited_by_user_id)
          #|VALUES (4, 'team_member', 'first@example.com', 'first', 'First', ?, 1, 'admin', 3),
          #|  (5, 'team_member', 'second@example.com', 'second', 'Second', ?, 1, 'member', 3)
        ),
        params=[password_hash, password_hash],
      )
    })
    let first_cookie = login_test_user(port, "first", password)
    let second_cookie = login_test_user(port, "second", password)
    let second_other_cookie = login_test_user(port, "second", password)
    let second_invitation = lookup_invitation_session(pool, second_cookie.value).unwrap()
    let (accepted, body) = http_post_path_with_cookie(
      port, "/change-password", "new_password=AcceptedPassword123&confirm_password=AcceptedPassword123",
      second_cookie,
    )
    assert_eq(accepted.code, 303, msg=body)
    assert_true(accepted.headers.get("location") is Some("/"))
    let second = lookup_session_user(pool, accepted.cookies[0].value).unwrap()
    assert_eq(second.id, 4L)
    assert_eq(second.name_key, "second")
    assert_true(!second.is_site_admin)
    assert_true(lookup_invitation_session(pool, second_cookie.value) is None)
    assert_true(
      lookup_invitation_session(pool, second_other_cookie.value) is None,
    )
    assert_true(lookup_invitation_session(pool, first_cookie.value) is Some(_))
    pool.with_client(client => {
      let first = client.query_one(
        "SELECT status, accepted_user_id, accepted_at FROM invitation WHERE id = 4",
      )
      assert_eq((first.get_name("status") : String), "sent")
      assert_true((first.get_name("accepted_user_id") : Int64?) is None)
      assert_true((first.get_name("accepted_at") : String?) is None)
      let second = client.query_one(
        "SELECT status, accepted_user_id, accepted_at FROM invitation WHERE id = 5",
      )
      assert_eq((second.get_name("status") : String), "accepted")
      assert_eq((second.get_name("accepted_user_id") : Int64), 4L)
      assert_true((second.get_name("accepted_at") : String?) is Some(_))
      let membership = client.query_one(
        "SELECT role FROM team_member WHERE team_id = 1 AND user_id = 4",
      )
      assert_eq((membership.get_name("role") : String), "member")
    })
    assert_true(
      accept_invitation(pool, second_invitation, "AnotherPassword123") is None,
    )
    let second_login = authenticate_user(pool, "second", "AcceptedPassword123").unwrap()
    assert_true(second_login.invitation is None)
    assert_eq(lookup_session_user(pool, second_login.token).unwrap().id, 4L)
    let (accepted, body) = http_post_path_with_cookie(
      port, "/change-password", "new_password=AcceptedPassword123&confirm_password=AcceptedPassword123",
      first_cookie,
    )
    assert_eq(accepted.code, 303, msg=body)
    let first = lookup_session_user(pool, accepted.cookies[0].value).unwrap()
    assert_eq(first.id, 5L)
    assert_eq(first.name_key, "first")
    pool.with_client(client => {
      let first = client.query_one(
        "SELECT accepted_user_id FROM invitation WHERE id = 4 AND status = 'accepted'",
      )
      assert_eq((first.get_name("accepted_user_id") : Int64), 5L)
      let second = client.query_one(
        "SELECT accepted_user_id FROM invitation WHERE id = 5 AND status = 'accepted'",
      )
      assert_eq((second.get_name("accepted_user_id") : Int64), 4L)
      let membership = client.query_one(
        "SELECT role FROM team_member WHERE team_id = 1 AND user_id = 5",
      )
      assert_eq((membership.get_name("role") : String), "admin")
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "accepting an invitation cannot mark another invitation accepted for an existing user" {
  with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO invitation (id, kind, email, name_key, display_name,
          #|  password_hash, team_id, team_role, invited_by_user_id)
          #|VALUES (1, 'team_member', 'guest@example.com', 'guest', 'Guest', 'test', 1, 'member', 3),
          #|  (4, 'team_member', 'pending@example.com', 'pending', 'Pending', 'test', 1, 'member', 3);
        ),
      )
    })
    let login = accept_invitation(
      pool,
      { id: 1L, name_key: "guest", display_name: "Guest", },
      "AcceptedPassword123",
    ).unwrap()
    let guest = lookup_session_user(pool, login.token).unwrap()
    assert_eq(guest.id, 4L)
    assert_eq(guest.name_key, "guest")
    pool.with_client(client => {
      let accepted = client.query_one(
        "SELECT status, accepted_user_id FROM invitation WHERE id = 1",
      )
      assert_eq((accepted.get_name("status") : String), "accepted")
      assert_eq((accepted.get_name("accepted_user_id") : Int64), guest.id)
      let pending = client.query_one(
        "SELECT status, accepted_user_id, accepted_at FROM invitation WHERE id = 4",
      )
      assert_eq((pending.get_name("status") : String), "sent")
      assert_true((pending.get_name("accepted_user_id") : Int64?) is None)
      assert_true((pending.get_name("accepted_at") : String?) is None)
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "root activation records acceptance when user and invitation sequences differ" {
  with_ssh_settings_app((port, pool, _, _, _) => {
    let password = "RootInvitation123"
    pool.with_client(client => {
      let _ = client.execute(
        (
          #|INSERT INTO invitation (id, kind, email, name_key, display_name, password_hash, is_site_admin)
          #|VALUES (41, 'root', 'new-root@localhost', 'new-root', 'New root', ?, 1)
        ),
        params=[hash_password(password)],
      )
    })
    let cookie = login_test_user(port, "new-root", password)
    let invitation = lookup_invitation_session(pool, cookie.value).unwrap()
    let (accepted, body) = http_post_path_with_cookie(
      port, "/change-password", "new_password=AcceptedPassword123&confirm_password=AcceptedPassword123",
      cookie,
    )
    assert_eq(accepted.code, 303, msg=body)
    let user = lookup_session_user(pool, accepted.cookies[0].value).unwrap()
    assert_true(user.is_site_admin)
    assert_eq(user.id, 4L)
    assert_true(user.id != invitation.id)
    pool.with_client(client => {
      let row = client.query_one(
        "SELECT status, accepted_user_id FROM invitation WHERE id = ?",
        params=[invitation.id],
      )
      assert_eq((row.get_name("status") : String), "accepted")
      assert_eq((row.get_name("accepted_user_id") : Int64), user.id)
      let membership = client.query_one(
        "SELECT t.name_key, t.kind, m.role FROM team_member AS m JOIN team AS t ON t.id = m.team_id WHERE m.user_id = ?",
        params=[user.id],
      )
      assert_eq((membership.get_name("name_key") : String), "new-root")
      assert_eq((membership.get_name("kind") : String), "personal")
      assert_eq((membership.get_name("role") : String), "owner")
    })
  })
}

///|
async test "failed invitation acceptance rolls back and the same invitation can be retried" {
  with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO invitation (id, kind, email, name_key, display_name,
          #|  password_hash, team_id, team_role, invited_by_user_id)
          #|VALUES (4, 'team_member', 'guest@example.com', 'guest', 'Guest', 'test', 1, 'member', 3);
          #|CREATE TEMP TRIGGER reject_acceptance BEFORE UPDATE OF status ON invitation
          #|WHEN NEW.status = 'accepted'
          #|BEGIN SELECT RAISE(ABORT, 'forced acceptance failure'); END;
        ),
      )
    })
    let token = pool.with_client(client => {
      client.with_transaction(tx => create_invitation_session_token(tx, 4L))
    })
    let invitation = lookup_invitation_session(pool, token).unwrap()
    try accept_invitation(pool, invitation, "AcceptedPassword123") catch {
      @moondb.QueryError(message) =>
        assert_true(message.contains("forced acceptance failure"))
      err => raise err
    } noraise {
      _ => fail("expected acceptance to roll back")
    }
    assert_true(lookup_invitation_session(pool, token) is Some(_))
    pool.with_client(client => {
      assert_true(
        client.query_opt("SELECT id FROM \"user\" WHERE name_key = 'guest'")
        is None,
      )
      assert_true(
        client.query_opt("SELECT user_id FROM team_member WHERE user_id = 4")
        is None,
      )
      assert_true(
        client.query_opt("SELECT id FROM session WHERE user_id = 4") is None,
      )
      let row = client.query_one(
        "SELECT status, accepted_at, accepted_user_id FROM invitation WHERE id = 4",
      )
      assert_eq((row.get_name("status") : String), "sent")
      assert_true((row.get_name("accepted_at") : String?) is None)
      assert_true((row.get_name("accepted_user_id") : Int64?) is None)
      client.batch_execute("DROP TRIGGER reject_acceptance")
    })
    let login = accept_invitation(pool, invitation, "AcceptedPassword123").unwrap()
    assert_eq(lookup_session_user(pool, login.token).unwrap().name_key, "guest")
    assert_true(lookup_invitation_session(pool, token) is None)
  })
}
