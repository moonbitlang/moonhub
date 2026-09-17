///|
async test "deleted invitations never deliver orphaned invitation credentials" {
  @test_support.with_ssh_test_db(pool => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "workshop").unwrap()
    let id = @identity.invite_team_member(
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
async test "mail claims exclude in-flight deliveries and recover stale claims" {
  @test_support.with_ssh_test_db(pool => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "workshop").unwrap()
    let id = @identity.invite_team_member(
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
    try @identity.resend_invitation_email(pool, actor, team.id, id) catch {
      @domain.NotFound(_) => ()
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
