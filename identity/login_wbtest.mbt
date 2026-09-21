///|
async test "login accepts usernames and normalized full emails without changing passwords" {
  @test_support.with_ssh_test_db(pool => {
    let password = " LoginPassword123 "
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET password_hash = ? WHERE id IN (1, 2)",
        params=[hash_password(password)],
      )
      let _ = client.execute(
        "UPDATE \"user\" SET email = 'alice+work@example.com' WHERE id = 1",
      )
    })
    for
      identifier in [
        "alice", " alice ", "alice+work@example.com", "  ALICE+WORK@EXAMPLE.COM  ",
      ] {
      let login = authenticate_user(pool, identifier, password).unwrap()
      assert_true(login.invitation is None)
      let user = lookup_session_user(pool, login.token).unwrap()
      assert_eq(user.id, 1L)
      assert_eq(user.name_key, "alice")
      revoke_session(pool, login.token)
    }
    let bob = authenticate_user(pool, "bob", password).unwrap()
    assert_eq(lookup_session_user(pool, bob.token).unwrap().id, 2L)
    for
      identifier in [
        "", "   ", "Alice", "alice+work", "alice@example.com", "alice+work@other.example",
        "bob@example.com", "' OR 1=1 --",
      ] {
      assert_true(
        authenticate_user(pool, identifier, password) is None,
        msg=identifier,
      )
    }
    for invalid_password in ["LoginPassword123", " loginpassword123 ", "wrong"] {
      assert_true(
        authenticate_user(pool, "alice+work@example.com", invalid_password)
        is None,
      )
    }
  })
}

///|
async test "email login respects invitation activation revocation and expiry" {
  @test_support.with_ssh_test_db(pool => {
    let password = "InvitationPassword123"
    pool.with_client(client => {
      let _ = client.execute(
        (
          #|INSERT INTO invitation (id, kind, email, name_key, display_name, password_hash,
          #|  team_id, team_role, invited_by_user_id)
          #|VALUES (41, 'team_member', 'guest+team@example.com', 'guest', 'Guest', ?, 3, 'member', 3)
        ),
        params=[hash_password(password)],
      )
    })
    for
      identifier in [
        "guest", "guest+team@example.com", " GUEST+TEAM@EXAMPLE.COM ",
      ] {
      let login = authenticate_user(pool, identifier, password).unwrap()
      assert_eq(login.invitation.unwrap().id, 41L)
      assert_true(lookup_session_user(pool, login.token) is None)
      assert_eq(
        lookup_invitation_session(pool, login.token).unwrap().name_key,
        "guest",
      )
    }
    assert_true(
      authenticate_user(pool, "guest+team@example.com", "wrong") is None,
    )
    for
      mutation in [
        "UPDATE invitation SET status = 'revoked' WHERE id = 41", "UPDATE invitation SET status = 'expired' WHERE id = 41",
        "UPDATE invitation SET status = 'accepted' WHERE id = 41", "UPDATE invitation SET expires_at = datetime('now', '-1 second') WHERE id = 41",
      ] {
      pool.with_client(client => client.batch_execute(mutation))
      assert_true(
        authenticate_user(pool, "guest+team@example.com", password) is None,
      )
      pool.with_client(client => {
        let _ = client.execute(
          "UPDATE invitation SET status = 'sent', expires_at = datetime('now', '+1 day') WHERE id = 41",
        )
      })
    }
    let login = authenticate_user(pool, "guest+team@example.com", password).unwrap()
    let invitation = lookup_invitation_session(pool, login.token).unwrap()
    let accepted = accept_invitation(pool, invitation, "PermanentPassword123").unwrap()
    let user = lookup_session_user(pool, accepted.token).unwrap()
    let email_login = authenticate_user(
      pool, "GUEST+TEAM@EXAMPLE.COM", "PermanentPassword123",
    ).unwrap()
    assert_true(email_login.invitation is None)
    assert_eq(lookup_session_user(pool, email_login.token).unwrap().id, user.id)
    assert_true(
      authenticate_user(pool, "guest+team@example.com", password) is None,
    )
  })
}

///|
async test "existing accounts never fall back to matching invitation credentials" {
  @test_support.with_ssh_test_db(pool => {
    let password = "AccountPassword123"
    let invitation_password = "InvitationPassword123"
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET email = 'alice@example.com', password_hash = ? WHERE id = 1",
        params=[hash_password(password)],
      )
      let _ = client.execute(
        (
          #|INSERT INTO invitation (kind, email, name_key, display_name, password_hash,
          #|  team_id, team_role, invited_by_user_id)
          #|VALUES ('team_member', 'alice@example.com', 'alice', 'Alice', ?, 3, 'member', 3)
        ),
        params=[hash_password(invitation_password)],
      )
    })
    for identifier in ["alice", "alice@example.com"] {
      assert_true(
        authenticate_user(pool, identifier, invitation_password) is None,
      )
    }
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'disabled' WHERE id = 1",
      )
    })
    for identifier in ["alice", "ALICE@EXAMPLE.COM"] {
      assert_true(authenticate_user(pool, identifier, password) is None)
      assert_true(
        authenticate_user(pool, identifier, invitation_password) is None,
      )
    }
    pool.with_client(client => {
      assert_true(client.query_all("SELECT id FROM session").is_empty())
      assert_true(
        client.query_all("SELECT id FROM invitation_session").is_empty(),
      )
    })
  })
}
