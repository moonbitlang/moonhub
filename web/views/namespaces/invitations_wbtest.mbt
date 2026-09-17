///|
async test "duplicate invitation names and emails return validation errors without side effects" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, bob, _) => {
    let form = "email=guest%40example.com&name_key=guest&display_name=Guest&role=member"
    let (created, _) = @web_testkit.http_post_path_with_cookie(
      port, "/workshop/-/invitations", form, alice,
    )
    assert_eq(created.code, 303)
    for
      (path, cookie, email, name) in [
        ("/workshop/-/invitations", alice, "guest@example.com", "guest"),
        ("/workshop/-/invitations", alice, "other@example.com", "guest"),
        ("/workshop/-/invitations", alice, "GUEST@EXAMPLE.COM", "other"),
        ("/squad/-/invitations", bob, "guest@example.com", "guest"),
      ] {
      let (response, body) = @web_testkit.http_post_path_with_cookie(
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
      let (response, body) = @web_testkit.http_post_path_with_cookie(
        port,
        "/workshop/-/invitations",
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
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "workshop").unwrap()
    for name in ["expired", "revoked"] {
      let id = @identity.invite_team_member(
        pool,
        actor,
        team,
        "\{name}@example.com",
        name,
        "Guest",
        "member",
      )
      let token = pool.with_client(client => {
        client.with_transaction(tx => {
          @identity.create_invitation_session_token(tx, id)
        })
      })
      if name == "expired" {
        pool.with_client(client => {
          let _ = client.execute(
            "UPDATE invitation SET expires_at = datetime('now', '-1 second') WHERE id = ?",
            params=[id],
          )
        })
      } else {
        assert_true(@identity.revoke_invitation(pool, actor, team.id, id))
        assert_true(!@identity.revoke_invitation(pool, actor, team.id, id))
      }
      let (response, body) = @web_testkit.http_post_path_with_cookie(
        port,
        "/workshop/-/invitations",
        "email=\{name}@example.com&name_key=\{name}&display_name=Guest&role=admin",
        alice,
      )
      assert_eq(response.code, 303, msg=body)
      assert_true(@identity.lookup_invitation_session(pool, token) is None)
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
      let message = @mail.claim_next_email(pool, "worker").unwrap()
      let status : String = pool.with_client(client => {
        client
        .query_one(
          "SELECT i.status FROM invitation i JOIN email_outbox e ON e.invitation_id = i.id WHERE e.id = ?",
          params=[message.id],
        )
        .get_name("status")
      })
      assert_eq(status, "sent")
      @mail.mark_email_delivered(pool, message.id, "test-provider")
    }
    assert_true(@mail.claim_next_email(pool, "worker") is None)
  })
}

///|
async test "invalid invitation submissions never disclose a team's membership to outsiders" {
  @web_testkit.with_ssh_settings_app((port, pool, _, bob, _) => {
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET email = 'private-member@example.com' WHERE id = 1",
      )
    })
    for
      form in [
        "", "email=invalid&name_key=guest&display_name=Guest", "email=guest@example.com&name_key=guest&display_name=Guest",
      ] {
      let (response, body) = @web_testkit.http_post_path_with_cookie(
        port, "/workshop/-/invitations", form, bob,
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
async test "expired accepted and revoked invitation emails cannot be resent or delivered" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "workshop").unwrap()
    for state in ["expired", "accepted", "revoked"] {
      let id = @identity.invite_team_member(
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
      let (response, _) = @web_testkit.http_post_path_with_cookie(
        port,
        "/workshop/-/invitations/\{id}/resend",
        "",
        alice,
      )
      assert_eq(response.code, 404)
    }
    assert_true(@mail.claim_next_email(pool, "worker") is None)
  })
}

///|
async test "mail diagnostics remain private even on administrator invitation pages" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, admin) => {
    let actor = @identity.active_user_by_name(pool, "admin")
    let team = @identity.get_team_by_name_key(pool, "workshop").unwrap()
    let id = @identity.invite_team_member(
      pool, actor, team, "guest@example.com", "guest", "Guest", "member",
    )
    let message = @mail.claim_next_email(pool, "worker").unwrap()
    @mail.mark_email_failed(
      pool,
      message.id,
      @web_testkit.private_error_test_detail,
    )
    for cookie in [alice, admin] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port, "/workshop", cookie,
      )
      assert_eq(response.code, 200)
      assert_true(body.contains(@domain.email_delivery_error_message))
      assert_true(!body.contains("private-diagnostic-sentinel"))
    }
    let token = @web_context.form_csrf_token(
      admin.value,
      "invitation-credentials:3",
    )
    let (response, body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/workshop/-/invitations/\{id}/credentials",
      "csrf_token=\{token}",
      admin,
    )
    assert_eq(response.code, 200)
    assert_true(body.contains(@domain.email_delivery_error_message))
    assert_true(!body.contains("private-diagnostic-sentinel"))
    assert_eq(
      @identity.invitation_credentials(pool, actor, team.id, id).email_last_error,
      Some(@web_testkit.private_error_test_detail),
    )
  })
}

///|
async test "invitation queue failures roll back creation and expose only a generic error" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    pool.with_client(client => {
      client.batch_execute(
        "CREATE TRIGGER reject_mail BEFORE INSERT ON email_outbox BEGIN SELECT RAISE(ABORT, 'private-diagnostic-sentinel'); END;",
      )
    })
    let (response, body) = @web_testkit.http_post_path_with_cookie(
      port, "/workshop/-/invitations", "email=guest@example.com&name_key=guest&display_name=Guest",
      alice,
    )
    assert_eq(response.code, 500)
    assert_true(body.contains(@domain.internal_error_message))
    assert_true(!body.contains("private-diagnostic-sentinel"))
    assert_true(!body.contains("INSERT INTO"))
    pool.with_client(client => {
      assert_true(client.query_all("SELECT id FROM invitation").is_empty())
      assert_true(client.query_all("SELECT id FROM email_outbox").is_empty())
      client.batch_execute("DROP TRIGGER reject_mail")
    })
    let (response, _) = @web_testkit.http_post_path_with_cookie(
      port, "/workshop/-/invitations", "email=guest@example.com&name_key=guest&display_name=Guest",
      alice,
    )
    assert_eq(response.code, 303)
  })
}
