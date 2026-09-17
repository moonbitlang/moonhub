///|
async test "only site administrators can reveal invitation emails without exposing them in lists" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, bob, admin) => {
    let actor = @identity.active_user_by_name(pool, "admin")
    let team = @identity.get_team_by_name_key(pool, "workshop").unwrap()
    let id = @identity.invite_team_member(
      pool, actor, team, "guest@example.com", "guest", "Guest", "member",
    )
    let path = "/workshop/-/invitations/\{id}/credentials"
    let email = @identity.invitation_credentials(pool, actor, team.id, id)
    for cookie in [alice, admin] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port, "/workshop", cookie,
      )
      assert_eq(response.code, 200)
      assert_true(response.headers.get("cache-control") is Some("no-store"))
      assert_true(!body.contains("One-time password:"))
      assert_true(!body.contains(email.body))
      assert_eq(body.contains(path), cookie.value == admin.value)
    }
    for role in ["owner", "admin", "member"] {
      pool.with_client(client => {
        let _ = client.execute(
          "UPDATE team_member SET role = ? WHERE team_id = 3 AND user_id = 1",
          params=[role],
        )
      })
      let (_, listed) = @web_testkit.http_get_path_with_cookie(
        port, "/workshop", alice,
      )
      assert_true(!listed.contains(path))
      let (denied, body) = @web_testkit.http_post_path_with_cookie(
        port,
        path,
        "csrf_token=\{@web_context.form_csrf_token(alice.value, "invitation-credentials:3")}",
        alice,
      )
      assert_eq(denied.code, 403)
      assert_true(!body.contains(email.body))
    }
    let (denied, _) = @web_testkit.http_post_path_with_cookie(
      port, path, "", bob,
    )
    assert_eq(denied.code, 403)
    try
      @identity.invitation_credentials(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        team.id,
        id,
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("team member read invitation credentials")
    }
    let (_, listed) = @web_testkit.http_get_path_with_cookie(
      port, "/workshop", admin,
    )
    let csrf = @web_testkit.extract_attr(
      listed, "name=\"csrf_token\"", "value=\"",
    )
    for status in ["pending", "failed", "sent"] {
      pool.with_client(client => {
        let _ = client.execute(
          "UPDATE email_outbox SET status = ? WHERE invitation_id = ?",
          params=[status, id],
        )
      })
      let (response, body) = @web_testkit.http_post_path_with_cookie(
        port,
        path,
        "csrf_token=\{csrf}",
        admin,
      )
      assert_eq(response.code, 200)
      assert_true(response.headers.get("cache-control") is Some("no-store"))
      assert_true(response.headers.get("x-frame-options") is Some("DENY"))
      assert_true(
        response.headers.get("referrer-policy") is Some("same-origin"),
      )
      assert_true(body.contains(email.body))
      assert_true(body.contains(email.email))
      assert_true(body.contains(email.expires_at))
      assert_true(body.contains("<dd>\{status}</dd>"))
    }
    assert_eq(
      @identity.invitation_credentials(pool, actor, team.id, id).body,
      email.body,
    )
    let marker = "One-time password: "
    let start = email.body.find(marker).unwrap() + marker.length()
    let end = start + email.body[start:].find("\n").unwrap()
    let password = email.body[start:end].to_owned()
    let guest_cookie = @web_testkit.login_test_user(port, "guest", password)
    let (accepted, _) = @web_testkit.http_post_path_with_cookie(
      port, "/-/change-password", "new_password=AcceptedPassword123&confirm_password=AcceptedPassword123",
      guest_cookie,
    )
    assert_eq(accepted.code, 303)
    assert_true(@identity.authenticate_user(pool, "guest", password) is None)
    let (unavailable, body) = @web_testkit.http_post_path_with_cookie(
      port,
      path,
      "csrf_token=\{csrf}",
      admin,
    )
    assert_eq(unavailable.code, 404)
    assert_true(!body.contains(password))
  })
}

///|
async test "revealing invitation credentials requires an active admin session and scoped CSRF token" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, admin) => {
    let actor = @identity.active_user_by_name(pool, "admin")
    let team = @identity.get_team_by_name_key(pool, "workshop").unwrap()
    let id = @identity.invite_team_member(
      pool, actor, team, "guest@example.com", "guest", "Guest", "member",
    )
    let path = "/workshop/-/invitations/\{id}/credentials"
    let csrf = @web_context.form_csrf_token(
      admin.value,
      "invitation-credentials:3",
    )
    for
      token in [
        "",
        "invalid",
        @web_context.form_csrf_token(alice.value, "invitation-credentials:3"),
        @web_context.form_csrf_token(admin.value, "invitation-credentials:2"),
        @web_context.form_csrf_token(admin.value, "ssh-key-settings"),
      ] {
      let (response, body) = @web_testkit.http_post_path_with_cookie(
        port,
        path,
        "csrf_token=\{token}",
        admin,
      )
      assert_eq(response.code, 403)
      assert_true(!body.contains("One-time password:"))
    }
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let cross_site = client.post(path, "csrf_token=\{csrf}", extra_headers={
      "Content-Type": "application/x-www-form-urlencoded",
      "Cookie": "\{admin.name}=\{admin.value}",
      "Sec-Fetch-Site": "cross-site",
    })
    assert_eq(cross_site.code, 403)
    assert_true(!client.read_all().text().contains("One-time password:"))
    let (get, body) = @web_testkit.http_get_path_with_cookie(port, path, admin)
    assert_true(get.code != 200)
    assert_true(!body.contains("One-time password:"))
    let (anonymous, _) = @web_testkit.http_post_path_with_cookie(
      port,
      path,
      "csrf_token=\{csrf}",
      @web_context.session_cookie("invalid-session"),
    )
    assert_eq(anonymous.code, 303)
    assert_true(anonymous.headers.get("location") is Some("/-/login"))
    let invitation_cookie = pool.with_client(client => {
      client.with_transaction(tx => {
        @web_context.session_cookie(
          @identity.create_invitation_session_token(tx, id),
        )
      })
    })
    let (invited, _) = @web_testkit.http_post_path_with_cookie(
      port, path, "", invitation_cookie,
    )
    assert_eq(invited.code, 303)
    assert_true(invited.headers.get("location") is Some("/-/change-password"))
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET is_site_admin = 0 WHERE id = 3",
      )
    })
    let (demoted, _) = @web_testkit.http_post_path_with_cookie(
      port,
      path,
      "csrf_token=\{csrf}",
      admin,
    )
    assert_eq(demoted.code, 403)
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET is_site_admin = 1, status = 'disabled' WHERE id = 3",
      )
    })
    let (disabled, _) = @web_testkit.http_post_path_with_cookie(
      port,
      path,
      "csrf_token=\{csrf}",
      admin,
    )
    assert_eq(disabled.code, 303)
    assert_true(disabled.headers.get("location") is Some("/-/login"))
  })
}

///|
async test "invitation credentials reject mismatched teams and unavailable invitations" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, admin) => {
    let actor = @identity.active_user_by_name(pool, "admin")
    let team = @identity.get_team_by_name_key(pool, "workshop").unwrap()
    let id = @identity.invite_team_member(
      pool, actor, team, "guest@example.com", "guest", "Guest", "member",
    )
    for
      (name, team_id, invitation_id) in [("bob", 2L, id), ("alice", 1L, 99999L)] {
      let (response, body) = @web_testkit.http_post_path_with_cookie(
        port,
        "/\{name}/-/invitations/\{invitation_id}/credentials",
        "csrf_token=\{@web_context.form_csrf_token(admin.value, "invitation-credentials:\{team_id}")}",
        admin,
      )
      assert_eq(response.code, 404)
      assert_true(!body.contains("One-time password:"))
    }
    for state in ["accepted", "revoked", "expired", "elapsed", "missing-email"] {
      pool.with_client(client => {
        let _ = client.execute(
          "UPDATE invitation SET status = ?, expires_at = datetime('now', ?) WHERE id = ?",
          params=[
            if state == "elapsed" || state == "missing-email" {
              "sent"
            } else {
              state
            },
            if state == "elapsed" {
              "-1 second"
            } else {
              "+7 days"
            },
            id,
          ],
        )
        if state == "missing-email" {
          let _ = client.execute(
            "DELETE FROM email_outbox WHERE invitation_id = ?",
            params=[id],
          )
        }
      })
      let path = "/workshop/-/invitations/\{id}/credentials"
      let (_, listed) = @web_testkit.http_get_path_with_cookie(
        port, "/workshop", admin,
      )
      assert_true(!listed.contains(path), msg=state)
      let (response, body) = @web_testkit.http_post_path_with_cookie(
        port,
        path,
        "csrf_token=\{@web_context.form_csrf_token(admin.value, "invitation-credentials:3")}",
        admin,
      )
      assert_eq(response.code, 404, msg=state)
      assert_true(!body.contains("One-time password:"))
    }
  })
}

///|
async test "invitation detail uses the latest invitation email and escapes all mail content" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, admin) => {
    let actor = @identity.active_user_by_name(pool, "admin")
    let team = @identity.get_team_by_name_key(pool, "workshop").unwrap()
    let id = @identity.invite_team_member(
      pool, actor, team, "guest@example.com", "guest", "Guest", "member",
    )
    let original = @identity.invitation_credentials(pool, actor, team.id, id).body
    pool.with_client(client => {
      let _ = client.execute(
        (
          #|INSERT INTO email_outbox (invitation_id, to_email, subject, body, template, status, last_error, sent_at)
          #|VALUES (?, 'guest@example.com', '<img src=x>', ?, 'team_invitation', 'failed', '<script>error</script>', datetime('now')),
          #|  (?, 'guest@example.com', 'Other email', 'Unrelated secret', 'plain', 'pending', NULL, NULL)
        ),
        params=[id, original + "\n</pre><script>mail</script>", id],
      )
    })
    let (response, body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/workshop/-/invitations/\{id}/credentials",
      "csrf_token=\{@web_context.form_csrf_token(admin.value, "invitation-credentials:3")}",
      admin,
    )
    assert_eq(response.code, 200)
    assert_true(body.contains(original))
    assert_true(body.contains("&lt;img src=x&gt;"))
    assert_true(body.contains("&lt;/pre&gt;&lt;script&gt;mail&lt;/script&gt;"))
    assert_true(body.contains(@domain.email_delivery_error_message))
    assert_true(!body.contains("&lt;script&gt;error&lt;/script&gt;"))
    assert_true(!body.contains("<img src=x>"))
    assert_true(!body.contains("<script>"))
    assert_true(!body.contains("Unrelated secret"))
  })
}
