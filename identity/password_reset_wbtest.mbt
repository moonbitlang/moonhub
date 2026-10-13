///|
fn latest_reset_code(pool : @database.Database) -> String raise {
  pool.with_client(client => {
    let row = client.query_one(
      "SELECT body FROM email_outbox WHERE template = 'password_reset' ORDER BY id DESC LIMIT 1",
    )
    let body : String = row.get_name("body")
    let start = body.find("Reset code: ").unwrap() + "Reset code: ".length()
    body[start:start + 32].to_owned()
  })
}

///|
async test "password reset consumes all codes sessions and tokens but preserves unrelated users" {
  @test_support.with_ssh_test_db(pool => {
    let original = hash_password("OriginalPassword123")
    let (alice_session, another_session, bob_session) = pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET email = 'alice@example.com', password_hash = ? WHERE id = 1",
        params=[original],
      )
      client.with_transaction(tx => {
        (
          create_session_token(tx, 1L),
          create_session_token(tx, 1L),
          create_session_token(tx, 2L),
        )
      })
    })
    let alice = active_user_by_name(pool, "alice")
    let bob = active_user_by_name(pool, "bob")
    let alice_token = create_access_token(pool, alice, "Recovery", "merge", 30)
    let bob_token = create_access_token(pool, bob, "Unrelated", "read", 30)
    assert_true(
      !reset_password(pool, "alice@example.com", "invalid", "NewPassword123"),
    )
    assert_eq(
      authenticate_access_token(pool, alice_token, "merge").id,
      alice.id,
    )
    request_password_reset(pool, "  ALICE@EXAMPLE.COM  ")
    let first_code = latest_reset_code(pool)
    pool.with_client(client => {
      let row = client.query_one(
        "SELECT token_hash, used_at FROM password_reset",
      )
      assert_eq((row.get_name("token_hash") : String), hash_token(first_code))
      assert_true((row.get_name("used_at") : String?) is None)
      let _ = client.execute(
        "UPDATE password_reset SET created_at = datetime('now', '-2 minutes')",
      )
    })
    request_password_reset(pool, "alice@example.com")
    let other_code = latest_reset_code(pool)
    assert_true(first_code != other_code)
    assert_true(lookup_session_user(pool, alice_session) is Some(_))
    assert_true(
      authenticate_user(pool, "alice", "OriginalPassword123") is Some(_),
    )
    assert_true(
      reset_password(
        pool,
        "ALICE@EXAMPLE.COM",
        "  \{first_code.to_upper()}  ",
        "NewPassword123",
      ),
    )
    assert_true(
      !reset_password(
        pool, "alice@example.com", first_code, "AnotherPassword123",
      ),
    )
    assert_true(
      !reset_password(
        pool, "alice@example.com", other_code, "AnotherPassword123",
      ),
    )
    assert_true(lookup_session_user(pool, alice_session) is None)
    assert_true(lookup_session_user(pool, another_session) is None)
    assert_true(lookup_session_user(pool, bob_session) is Some(_))
    try authenticate_access_token(pool, alice_token, "read") catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("password recovery left the old access token usable")
    }
    assert_eq(authenticate_access_token(pool, bob_token, "read").id, bob.id)
    assert_true(authenticate_user(pool, "alice", "OriginalPassword123") is None)
    let login = authenticate_user(pool, "alice", "NewPassword123").unwrap()
    assert_eq(lookup_session_user(pool, login.token).unwrap().id, 1L)
    pool.with_client(client => {
      assert_true(
        client
        .query_all("SELECT id FROM password_reset WHERE used_at IS NULL")
        .is_empty(),
      )
      for
        row in client.query_all(
          "SELECT body, status FROM email_outbox WHERE template = 'password_reset'",
        ) {
        let body : String = row.get_name("body")
        assert_true(!body.contains(first_code) && !body.contains(other_code))
        assert_eq((row.get_name("status") : String), "failed")
      }
      let notification = client.query_one(
        "SELECT to_email FROM email_outbox WHERE template = 'password_changed'",
      )
      assert_eq(
        (notification.get_name("to_email") : String),
        "alice@example.com",
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "reset codes reject wrong emails expired disabled changed-email and deleted accounts" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET email = 'alice@example.com' WHERE id = 1",
      )
    })
    request_password_reset(pool, "alice@example.com")
    let code = latest_reset_code(pool)
    assert_true(
      !reset_password(pool, "bob@example.com", code, "NewPassword123"),
    )
    for
      invalid in [
        "",
        "00000000000000000000000000000000",
        "not-a-code",
        code + "0",
      ] {
      assert_true(
        !reset_password(pool, "alice@example.com", invalid, "NewPassword123"),
      )
    }
    for
      mutation in [
        "UPDATE password_reset SET expires_at = datetime('now', '-1 second')", "UPDATE \"user\" SET status = 'disabled' WHERE id = 1",
        "UPDATE \"user\" SET email = 'other@example.com' WHERE id = 1",
      ] {
      pool.with_client(client => client.batch_execute(mutation))
      assert_true(
        !reset_password(pool, "alice@example.com", code, "NewPassword123"),
      )
      pool.with_client(client => {
        client.batch_execute(
          "UPDATE password_reset SET expires_at = datetime('now', '+30 minutes'); UPDATE \"user\" SET email = 'alice@example.com', status = 'active' WHERE id = 1;",
        )
      })
    }
    pool.with_client(client => {
      let row = client.query_one(
        "SELECT password_hash FROM \"user\" WHERE id = 1",
      )
      assert_eq((row.get_name("password_hash") : String), "test")
      let _ = client.execute("DELETE FROM \"user\" WHERE id = 1")
    })
    assert_true(
      !reset_password(pool, "alice@example.com", code, "NewPassword123"),
    )
  })
}

///|
async test "password recovery ignores unknown disabled and unaccepted accounts and limits email" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|UPDATE "user" SET email = 'alice@example.com' WHERE id = 1;
          #|UPDATE "user" SET email = 'bob@example.com', status = 'disabled' WHERE id = 2;
          #|INSERT INTO invitation (kind, email, name_key, display_name, password_hash, is_site_admin)
          #|VALUES ('root', 'pending@example.com', 'pending', 'Pending', 'test', 1);
        ),
      )
    })
    for
      email in [
        "unknown@example.com", "bob@example.com", "pending@example.com", "bad-email",
        "",
      ] {
      request_password_reset(pool, email)
    }
    pool.with_client(client => {
      assert_true(client.query_all("SELECT id FROM password_reset").is_empty())
      assert_true(client.query_all("SELECT id FROM email_outbox").is_empty())
    })
    for i = 0; i < 5; i = i + 1 {
      request_password_reset(pool, "alice@example.com")
      request_password_reset(pool, "ALICE@EXAMPLE.COM")
      pool.with_client(client => {
        assert_eq(
          client.query_all("SELECT id FROM password_reset").length(),
          i + 1,
        )
        let _ = client.execute(
          "UPDATE password_reset SET created_at = datetime('now', '-2 minutes')",
        )
      })
    }
    request_password_reset(pool, "alice@example.com")
    pool.with_client(client => {
      assert_eq(client.query_all("SELECT id FROM email_outbox").length(), 5)
      let _ = client.execute(
        "UPDATE password_reset SET created_at = datetime('now', '-61 minutes')",
      )
    })
    request_password_reset(pool, "alice@example.com")
    pool.with_client(client => {
      assert_eq(client.query_all("SELECT id FROM email_outbox").length(), 6)
    })
  })
}

///|
async test "password reset and outbox insertion failures roll back atomically" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|UPDATE "user" SET email = 'alice@example.com' WHERE id = 1;
          #|CREATE TEMP TRIGGER reject_reset_mail BEFORE INSERT ON email_outbox
          #|BEGIN SELECT RAISE(ABORT, 'forced mail failure'); END;
        ),
      )
    })
    try request_password_reset(pool, "alice@example.com") catch {
      @moondb.QueryError(_) => ()
      err => raise err
    } noraise {
      _ => fail("expected mail failure")
    }
    let session = pool.with_client(client => {
      assert_true(client.query_all("SELECT id FROM password_reset").is_empty())
      client.batch_execute("DROP TRIGGER reject_reset_mail")
      client.with_transaction(tx => create_session_token(tx, 1L))
    })
    let access_token = create_access_token(
      pool,
      active_user_by_name(pool, "alice"),
      "Recovery rollback",
      "read",
      30,
    )
    request_password_reset(pool, "alice@example.com")
    let code = latest_reset_code(pool)
    pool.with_client(client => {
      client.batch_execute(
        "CREATE TEMP TRIGGER reject_reset BEFORE UPDATE ON access_token BEGIN SELECT RAISE(ABORT, 'forced token failure'); END;",
      )
    })
    try
      reset_password(pool, "alice@example.com", code, "NewPassword123")
    catch {
      @moondb.QueryError(_) => ()
      err => raise err
    } noraise {
      _ => fail("expected reset failure")
    }
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT password_hash FROM \"user\" WHERE id = 1")
          .get_name("password_hash") : String),
        "test",
      )
      assert_true(
        (
          client
          .query_one("SELECT used_at FROM password_reset")
          .get_name("used_at") : String?)
        is None,
      )
      client.batch_execute("DROP TRIGGER reject_reset")
    })
    assert_true(lookup_session_user(pool, session) is Some(_))
    assert_eq(authenticate_access_token(pool, access_token, "read").id, 1L)
    assert_eq(latest_reset_code(pool), code)
    assert_true(
      reset_password(pool, "alice@example.com", code, "NewPassword123"),
    )
  })
}

///|
test "recovery password policy handles bcrypt byte limits" {
  assert_true(new_password_error("short") is Some(_))
  assert_true(new_password_error("a".repeat(8)) is None)
  assert_true(new_password_error("a".repeat(72)) is None)
  assert_true(new_password_error("a".repeat(73)) is Some(_))
  assert_true(new_password_error("\u4e00".repeat(24)) is None)
  assert_true(new_password_error("\u4e00".repeat(25)) is Some(_))
}
