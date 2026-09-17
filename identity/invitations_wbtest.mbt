///|
async test "accepting an invitation cannot mark another invitation accepted for an existing user" {
  @test_support.with_ssh_test_db(pool => {
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
async test "failed invitation acceptance rolls back and the same invitation can be retried" {
  @test_support.with_ssh_test_db(pool => {
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

///|
test "invitation email validation rejects malformed addresses and control characters" {
  for
    value in [
      "", "@", "guest@", "@example.com", "guest@@example.com", "guest\n@example.com",
      "guest\r@example.com", "guest\t@example.com", "guest\u0000@example.com",
    ] {
    assert_true(!@domain.valid_email(value), msg=value)
  }
  assert_true(@domain.valid_email("guest+team@example.com"))
  assert_true(
    @domain.valid_email(@domain.normalize_email(" GUEST@EXAMPLE.COM ")),
  )
}
