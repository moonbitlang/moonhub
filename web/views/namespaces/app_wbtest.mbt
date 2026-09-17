///|
async test "root invitation creates team and revoked team invitation cannot sign in" {
  @web_testkit.with_production_test_app(async fn(_app, port, pool) {
    let root_invitation_cookie = @web_testkit.login_test_user(
      port, @web_testkit.test_auth_name_key, @web_testkit.test_auth_password,
    )
    let (change_response, _) = @web_testkit.http_post_path_with_cookie(
      port, "/-/change-password", "new_password=changedPassword123&confirm_password=changedPassword123",
      root_invitation_cookie,
    )
    assert_eq(change_response.code, 303)

    let root_cookie = @web_testkit.login_test_user(
      port, @web_testkit.test_auth_name_key, "changedPassword123",
    )
    let (teams_response, teams_body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/teams", root_cookie,
    )
    assert_eq(teams_response.code, 200)
    assert_true(teams_body.contains("New team"))

    let (create_response, _) = @web_testkit.http_post_path_with_cookie(
      port, "/-/teams", "name_key=moonhub_test_team&display_name=Moonhub%20Test%20Team",
      root_cookie,
    )
    assert_eq(create_response.code, 303)
    assert_true(
      create_response.headers.get("location") is Some("/moonhub_test_team"),
    )

    let invite_body = "email=invited-admin%40example.com&name_key=moonhub_invited_admin&display_name=Invited%20Admin&role=admin"
    let (invite_response, _) = @web_testkit.http_post_path_with_cookie(
      port, "/moonhub_test_team/-/invitations", invite_body, root_cookie,
    )
    assert_eq(invite_response.code, 303)
    let (pending_page_response, pending_page_body) = @web_testkit.http_get_path_with_cookie(
      port, "/moonhub_test_team", root_cookie,
    )
    assert_eq(pending_page_response.code, 200)
    assert_true(pending_page_body.contains("<th>Delivery</th>"))
    assert_true(pending_page_body.contains("data-delivery=\"pending\">Queued"))
    assert_true(pending_page_body.contains("Awaiting acceptance"))
    let one_time_password = @web_testkit.invited_admin_password_from_outbox(
      pool,
    )
    let outbox_id = @web_testkit.latest_invited_admin_outbox_id(pool)
    assert_true(
      @mail.deliver_next_email(
        pool,
        "test-worker",
        @mail.File(outbox_dir=@test_support.test_mail_outbox_dir),
      ),
    )
    let outbox_row = pool.with_client(client => {
      client.query_one(
        (
          #|SELECT
          #|  invitation_id,
          #|  status AS status,
          #|  provider_message_id
          #|FROM email_outbox
          #|WHERE id = ?
        ),
        params=[outbox_id],
      )
    })
    assert_eq((outbox_row.get_name("status") : String), "sent")
    assert_eq(
      (outbox_row.get_name("provider_message_id") : String),
      "file-\{outbox_id}",
    )
    let mail_text = @fs.read_file(
      "\{@test_support.test_mail_outbox_dir}/\{outbox_id}.eml",
    ).text()
    assert_true(mail_text.contains("To: invited-admin@example.com"))
    assert_true(mail_text.contains("One-time password: \{one_time_password}"))
    let invitation_row = pool.with_client(client => {
      client.query_one(
        (
          #|SELECT id, status AS status
          #|FROM invitation
          #|WHERE email = 'invited-admin@example.com'
          #|ORDER BY id DESC
          #|LIMIT 1
        ),
      )
    })
    let invitation_id : Int64 = invitation_row.get_name("id")
    assert_eq((invitation_row.get_name("status") : String), "sent")
    assert_eq((outbox_row.get_name("invitation_id") : Int64), invitation_id)
    pool.with_client(client => {
      let _ = client.execute(
        (
          #|UPDATE email_outbox
          #|SET status = 'failed',
          #|    attempt_count = 10,
          #|    last_error = 'test delivery failure'
          #|WHERE id = ?
        ),
        params=[outbox_id],
      )
    })
    let (_, failed_page_body) = @web_testkit.http_get_path_with_cookie(
      port, "/moonhub_test_team", root_cookie,
    )
    assert_true(failed_page_body.contains(">Resend</button>"))
    let (resend_response, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/moonhub_test_team/-/invitations/\{invitation_id.to_string()}/resend",
      "",
      root_cookie,
    )
    assert_eq(resend_response.code, 303)
    let resent_row = pool.with_client(client => {
      client.query_one(
        (
          #|SELECT
          #|  status AS status,
          #|  attempt_count,
          #|  last_error,
          #|  provider_message_id,
          #|  sent_at AS sent_at
          #|FROM email_outbox
          #|WHERE id = ?
        ),
        params=[outbox_id],
      )
    })
    assert_eq((resent_row.get_name("status") : String), "pending")
    assert_eq((resent_row.get_name("attempt_count") : Int64), 0L)
    assert_true((resent_row.get_name("last_error") : String?) is None)
    assert_true((resent_row.get_name("provider_message_id") : String?) is None)
    assert_true((resent_row.get_name("sent_at") : String?) is None)
    assert_true(
      @mail.deliver_next_email(
        pool,
        "test-worker",
        @mail.File(outbox_dir=@test_support.test_mail_outbox_dir),
      ),
    )
    let (sent_page_response, sent_page_body) = @web_testkit.http_get_path_with_cookie(
      port, "/moonhub_test_team", root_cookie,
    )
    assert_eq(sent_page_response.code, 200)
    assert_true(sent_page_body.contains("data-delivery=\"sent\">Delivered"))

    let (revoke_response, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/moonhub_test_team/-/invitations/\{invitation_id.to_string()}/revoke",
      "",
      root_cookie,
    )
    assert_eq(revoke_response.code, 303)
    let revoked_row = pool.with_client(client => {
      client.query_one(
        (
          #|SELECT status AS status
          #|FROM invitation
          #|WHERE id = ?
        ),
        params=[invitation_id],
      )
    })
    assert_eq((revoked_row.get_name("status") : String), "revoked")

    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let denied = client.post(
      "/-/login",
      "name_key=moonhub_invited_admin&password=\{one_time_password}",
      extra_headers={ "Content-Type": "application/x-www-form-urlencoded" },
    )
    client.skip_response_body()
    assert_eq(denied.code, 401)
  })
}
