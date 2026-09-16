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

///|
async test "duplicate invitation names and emails return validation errors without side effects" {
  with_ssh_settings_app((port, pool, alice, bob, _) => {
    let form = "email=guest%40example.com&name_key=guest&display_name=Guest&role=member"
    let (created, _) = http_post_path_with_cookie(
      port, "/teams/alice/invitations", form, alice,
    )
    assert_eq(created.code, 303)
    for
      (path, cookie, email, name) in [
        ("/teams/alice/invitations", alice, "guest@example.com", "guest"),
        ("/teams/alice/invitations", alice, "other@example.com", "guest"),
        ("/teams/alice/invitations", alice, "GUEST@EXAMPLE.COM", "other"),
        ("/teams/bob/invitations", bob, "guest@example.com", "guest"),
      ] {
      let (response, body) = http_post_path_with_cookie(
        port,
        path,
        "email=\{email}&name_key=\{name}&display_name=Guest&role=member",
        cookie,
      )
      assert_eq(response.code, 400)
      assert_true(
        body.contains(
          "an active invitation already uses this username or email",
        ),
      )
      assert_true(body.contains("Invite member"))
      assert_true(!body.contains("sql="))
      assert_true(!body.contains("UNIQUE constraint"))
      assert_true(response.headers.get("cache-control") is Some("no-store"))
    }
    pool.with_client(client => {
      assert_eq(client.query_all("SELECT id FROM invitation").length(), 1)
      assert_eq(client.query_all("SELECT id FROM email_outbox").length(), 1)
      let _ = client.execute(
        "UPDATE \"user\" SET email = 'bob@example.com' WHERE id = 2",
      )
    })
    for
      (email, name) in [("new@example.com", "bob"), ("bob@example.com", "new")] {
      let (response, body) = http_post_path_with_cookie(
        port,
        "/teams/alice/invitations",
        "email=\{email}&name_key=\{name}&display_name=Guest",
        alice,
      )
      assert_eq(response.code, 400)
      assert_true(body.contains("user name_key or email is already in use"))
      assert_true(!body.contains("sql="))
    }
  })
}

///|
async test "expired and revoked invitations can be replaced without reviving old credentials" {
  with_ssh_settings_app((port, pool, alice, _, _) => {
    let actor = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    for name in ["expired", "revoked"] {
      let id = invite_team_member(
        pool,
        actor,
        team,
        "\{name}@example.com",
        name,
        "Guest",
        "member",
      )
      let token = pool.with_client(client => {
        client.with_transaction(tx => create_invitation_session_token(tx, id))
      })
      if name == "expired" {
        pool.with_client(client => {
          let _ = client.execute(
            "UPDATE invitation SET expires_at = datetime('now', '-1 second') WHERE id = ?",
            params=[id],
          )
        })
      } else {
        assert_true(revoke_invitation(pool, actor, team.id, id))
        assert_true(!revoke_invitation(pool, actor, team.id, id))
      }
      let (response, body) = http_post_path_with_cookie(
        port,
        "/teams/alice/invitations",
        "email=\{name}@example.com&name_key=\{name}&display_name=Guest&role=admin",
        alice,
      )
      assert_eq(response.code, 303, msg=body)
      assert_true(lookup_invitation_session(pool, token) is None)
      pool.with_client(client => {
        let old = client.query_one(
          "SELECT status FROM invitation WHERE id = ?",
          params=[id],
        )
        assert_eq((old.get_name("status") : String), name)
        let current = client.query_one(
          "SELECT id, team_role FROM invitation WHERE name_key = ? AND status = 'sent'",
          params=[name],
        )
        assert_true((current.get_name("id") : Int64) > id)
        assert_eq((current.get_name("team_role") : String), "admin")
      })
    }
    for _ in 0..<2 {
      let message = claim_next_email(pool, "worker").unwrap()
      let status : String = pool.with_client(client => {
        client
        .query_one(
          "SELECT i.status FROM invitation i JOIN email_outbox e ON e.invitation_id = i.id WHERE e.id = ?",
          params=[message.id],
        )
        .get_name("status")
      })
      assert_eq(status, "sent")
      mark_email_delivered(pool, message.id, "test-provider")
    }
    assert_true(claim_next_email(pool, "worker") is None)
  })
}

///|
async test "deleted invitations never deliver orphaned invitation credentials" {
  with_ssh_test_db(pool => {
    let actor = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let id = invite_team_member(
      pool, actor, team, "guest@example.com", "guest", "Guest", "member",
    )
    pool.with_client(client => {
      let _ = client.execute("DELETE FROM invitation WHERE id = ?", params=[id])
      assert_true(
        client.query_opt(
          "SELECT id FROM email_outbox WHERE invitation_id IS NULL",
        )
        is Some(_),
      )
      let _ = client.execute(
        "INSERT INTO email_outbox (to_email, subject, body) VALUES ('guest@example.com', 'Plain email', 'Message')",
      )
    })
    let message = claim_next_email(pool, "worker").unwrap()
    assert_eq(message.subject, "Plain email")
    mark_email_delivered(pool, message.id, "test-provider")
    assert_true(claim_next_email(pool, "worker") is None)
  })
}

///|
async test "invalid invitation submissions never disclose a team's membership to outsiders" {
  with_ssh_settings_app((port, pool, _, bob, _) => {
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET email = 'private-member@example.com' WHERE id = 1",
      )
    })
    for
      form in [
        "", "email=invalid&name_key=guest&display_name=Guest", "email=guest@example.com&name_key=guest&display_name=Guest",
      ] {
      let (response, body) = http_post_path_with_cookie(
        port, "/teams/alice/invitations", form, bob,
      )
      assert_eq(response.code, 403)
      assert_true(!body.contains("private-member@example.com"))
      assert_true(!body.contains("Invite member"))
    }
    pool.with_client(client => {
      assert_true(client.query_all("SELECT id FROM invitation").is_empty())
    })
  })
}

///|
async test "accepting an invitation whose identity was claimed returns a public error" {
  for field in ["email", "name_key"] {
    with_ssh_settings_app((port, pool, _, _, _) => {
      let actor = active_user_by_name(pool, "alice")
      let team = get_team_by_name_key(pool, "alice").unwrap()
      let id = invite_team_member(
        pool, actor, team, "guest@example.com", "guest", "Guest", "member",
      )
      let cookie = pool.with_client(client => {
        client.with_transaction(tx => {
          session_cookie(create_invitation_session_token(tx, id))
        })
      })
      pool.with_client(client => {
        let _ = client.execute(
          if field == "email" {
            "UPDATE \"user\" SET email = 'guest@example.com' WHERE id = 2"
          } else {
            "UPDATE \"user\" SET name_key = 'guest' WHERE id = 2"
          },
        )
      })
      let (response, body) = http_post_path_with_cookie(
        port, "/change-password", "new_password=AcceptedPassword123&confirm_password=AcceptedPassword123",
        cookie,
      )
      assert_eq(response.code, 400)
      assert_true(body.contains("invitation is no longer valid"))
      assert_true(!body.contains("UNIQUE"))
      assert_true(!body.contains("sql="))
      pool.with_client(client => {
        assert_eq(client.query_all("SELECT id FROM \"user\"").length(), 3)
        assert_eq(
          (
            client
            .query_one("SELECT password_hash FROM \"user\" WHERE id = 2")
            .get_name("password_hash") : String),
          "test",
        )
        assert_true(
          client.query_opt(
            "SELECT user_id FROM team_member WHERE team_id = 1 AND user_id = 2",
          )
          is None,
        )
      })
    })
  }
}

///|
async test "expired accepted and revoked invitation emails cannot be resent or delivered" {
  with_ssh_settings_app((port, pool, alice, _, _) => {
    let actor = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    for state in ["expired", "accepted", "revoked"] {
      let id = invite_team_member(
        pool,
        actor,
        team,
        "\{state}@example.com",
        state,
        "Guest",
        "member",
      )
      pool.with_client(client => {
        let _ = if state == "expired" {
          client.execute(
            "UPDATE invitation SET expires_at = datetime('now', '-1 second') WHERE id = ?",
            params=[id],
          )
        } else {
          client.execute("UPDATE invitation SET status = ? WHERE id = ?", params=[
            state, id,
          ])
        }
        let _ = client.execute(
          "UPDATE email_outbox SET last_error = 'prior failure' WHERE invitation_id = ?",
          params=[id],
        )
      })
      let (response, _) = http_post_path_with_cookie(
        port,
        "/teams/alice/invitations/\{id}/resend",
        "",
        alice,
      )
      assert_eq(response.code, 404)
    }
    assert_true(claim_next_email(pool, "worker") is None)
  })
}

///|
async test "mail claims exclude in-flight deliveries and recover stale claims" {
  with_ssh_test_db(pool => {
    let actor = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let id = invite_team_member(
      pool, actor, team, "guest@example.com", "guest", "Guest", "member",
    )
    let message = claim_next_email(pool, "first-worker").unwrap()
    assert_true(claim_next_email(pool, "second-worker") is None)
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE email_outbox SET last_error = 'old failure' WHERE invitation_id = ?",
        params=[id],
      )
    })
    try resend_invitation_email(pool, actor, team.id, id) catch {
      NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("reset an in-flight email delivery")
    }
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE email_outbox SET locked_at = datetime('now', '-6 minutes') WHERE id = ?",
        params=[message.id],
      )
    })
    assert_eq(claim_next_email(pool, "second-worker").unwrap().id, message.id)
  })
}

///|
async test "mail diagnostics remain private even on administrator invitation pages" {
  with_ssh_settings_app((port, pool, alice, _, admin) => {
    let actor = active_user_by_name(pool, "admin")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let id = invite_team_member(
      pool, actor, team, "guest@example.com", "guest", "Guest", "member",
    )
    let message = claim_next_email(pool, "worker").unwrap()
    mark_email_failed(pool, message.id, private_error_test_detail)
    for cookie in [alice, admin] {
      let (response, body) = http_get_path_with_cookie(
        port, "/teams/alice", cookie,
      )
      assert_eq(response.code, 200)
      assert_true(body.contains(email_delivery_error_message))
      assert_true(!body.contains("private-diagnostic-sentinel"))
    }
    let token = form_csrf_token(admin.value, "invitation-credentials:1")
    let (response, body) = http_post_path_with_cookie(
      port,
      "/teams/alice/invitations/\{id}/credentials",
      "csrf_token=\{token}",
      admin,
    )
    assert_eq(response.code, 200)
    assert_true(body.contains(email_delivery_error_message))
    assert_true(!body.contains("private-diagnostic-sentinel"))
    assert_eq(
      invitation_credentials(pool, actor, team.id, id).email_last_error,
      Some(private_error_test_detail),
    )
  })
}

///|
test "invitation email validation rejects malformed addresses and control characters" {
  for
    value in [
      "", "@", "guest@", "@example.com", "guest@@example.com", "guest\n@example.com",
      "guest\r@example.com", "guest\t@example.com", "guest\u0000@example.com",
    ] {
    assert_true(!valid_email(value), msg=value)
  }
  assert_true(valid_email("guest+team@example.com"))
  assert_true(valid_email(normalize_email(" GUEST@EXAMPLE.COM ")))
}

///|
async test "invitation queue failures roll back creation and expose only a generic error" {
  with_ssh_settings_app((port, pool, alice, _, _) => {
    pool.with_client(client => {
      client.batch_execute(
        "CREATE TRIGGER reject_mail BEFORE INSERT ON email_outbox BEGIN SELECT RAISE(ABORT, 'private-diagnostic-sentinel'); END;",
      )
    })
    let (response, body) = http_post_path_with_cookie(
      port, "/teams/alice/invitations", "email=guest@example.com&name_key=guest&display_name=Guest",
      alice,
    )
    assert_eq(response.code, 500)
    assert_true(body.contains(internal_error_message))
    assert_true(!body.contains("private-diagnostic-sentinel"))
    assert_true(!body.contains("INSERT INTO"))
    pool.with_client(client => {
      assert_true(client.query_all("SELECT id FROM invitation").is_empty())
      assert_true(client.query_all("SELECT id FROM email_outbox").is_empty())
      client.batch_execute("DROP TRIGGER reject_mail")
    })
    let (response, _) = http_post_path_with_cookie(
      port, "/teams/alice/invitations", "email=guest@example.com&name_key=guest&display_name=Guest",
      alice,
    )
    assert_eq(response.code, 303)
  })
}
