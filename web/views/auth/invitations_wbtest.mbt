///|
async test "team invitations accepted out of order reference the correct users" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, _) => {
    let password = "InvitationPassword123"
    let password_hash = @identity.hash_password(password)
    pool.with_client(client => {
      let _ = client.execute(
        (
          #|INSERT INTO invitation (id, kind, email, name_key, display_name,
          #|  password_hash, team_id, team_role, invited_by_user_id)
          #|VALUES (4, 'team_member', 'first@example.com', 'first', 'First', ?, 3, 'admin', 3),
          #|  (5, 'team_member', 'second@example.com', 'second', 'Second', ?, 3, 'member', 3)
        ),
        params=[password_hash, password_hash],
      )
    })
    let first_cookie = @web_testkit.login_test_user(port, "first", password)
    let second_cookie = @web_testkit.login_test_user(port, "second", password)
    let second_other_cookie = @web_testkit.login_test_user(
      port, "second", password,
    )
    let second_invitation = @identity.lookup_invitation_session(
      pool,
      second_cookie.value,
    ).unwrap()
    let (accepted, body) = @web_testkit.http_post_path_with_cookie(
      port, "/-/change-password", "new_password=AcceptedPassword123&confirm_password=AcceptedPassword123",
      second_cookie,
    )
    assert_eq(accepted.code, 303, msg=body)
    assert_true(accepted.headers.get("location") is Some("/"))
    let second = @identity.lookup_session_user(pool, accepted.cookies[0].value).unwrap()
    assert_eq(second.id, 4L)
    assert_eq(second.name_key, "second")
    assert_true(!second.is_site_admin)
    assert_true(
      @identity.lookup_invitation_session(pool, second_cookie.value) is None,
    )
    assert_true(
      @identity.lookup_invitation_session(pool, second_other_cookie.value)
      is None,
    )
    assert_true(
      @identity.lookup_invitation_session(pool, first_cookie.value) is Some(_),
    )
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
        "SELECT role FROM team_member WHERE team_id = 3 AND user_id = 4",
      )
      assert_eq((membership.get_name("role") : String), "member")
    })
    assert_true(
      @identity.accept_invitation(pool, second_invitation, "AnotherPassword123")
      is None,
    )
    let second_login = @identity.authenticate_user(
      pool, "second", "AcceptedPassword123",
    ).unwrap()
    assert_true(second_login.invitation is None)
    assert_eq(
      @identity.lookup_session_user(pool, second_login.token).unwrap().id,
      4L,
    )
    let (accepted, body) = @web_testkit.http_post_path_with_cookie(
      port, "/-/change-password", "new_password=AcceptedPassword123&confirm_password=AcceptedPassword123",
      first_cookie,
    )
    assert_eq(accepted.code, 303, msg=body)
    let first = @identity.lookup_session_user(pool, accepted.cookies[0].value).unwrap()
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
        "SELECT role FROM team_member WHERE team_id = 3 AND user_id = 5",
      )
      assert_eq((membership.get_name("role") : String), "admin")
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "root activation records acceptance when user and invitation sequences differ" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, _) => {
    let password = "RootInvitation123"
    pool.with_client(client => {
      let _ = client.execute(
        (
          #|INSERT INTO invitation (id, kind, email, name_key, display_name, password_hash, is_site_admin)
          #|VALUES (41, 'root', 'new-root@localhost', 'new-root', 'New root', ?, 1)
        ),
        params=[@identity.hash_password(password)],
      )
    })
    let cookie = @web_testkit.login_test_user(port, "new-root", password)
    let invitation = @identity.lookup_invitation_session(pool, cookie.value).unwrap()
    let (accepted, body) = @web_testkit.http_post_path_with_cookie(
      port, "/-/change-password", "new_password=AcceptedPassword123&confirm_password=AcceptedPassword123",
      cookie,
    )
    assert_eq(accepted.code, 303, msg=body)
    let user = @identity.lookup_session_user(pool, accepted.cookies[0].value).unwrap()
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
async test "accepting an invitation whose identity was claimed returns a public error" {
  for field in ["email", "name_key"] {
    @web_testkit.with_ssh_settings_app((port, pool, _, _, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let team = @identity.get_team_by_name_key(pool, "workshop").unwrap()
      let id = @identity.invite_team_member(
        pool, actor, team, "guest@example.com", "guest", "Guest", "member",
      )
      let cookie = pool.with_client(client => {
        client.with_transaction(tx => {
          @web_context.session_cookie(
            @identity.create_invitation_session_token(tx, id),
          )
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
      let (response, body) = @web_testkit.http_post_path_with_cookie(
        port, "/-/change-password", "new_password=AcceptedPassword123&confirm_password=AcceptedPassword123",
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
            "SELECT user_id FROM team_member WHERE team_id = 3 AND user_id = 2",
          )
          is None,
        )
      })
    })
  }
}
