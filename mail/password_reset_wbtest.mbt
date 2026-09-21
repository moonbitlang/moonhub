///|
async test "reset mail delivers through SMTP and removes the delivered code from the outbox" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET email = 'alice@example.com' WHERE id = 1",
      )
    })
    @identity.request_password_reset(pool, "alice@example.com")
    @async.with_task_group(group => {
      let server = @socket.TcpServer::TcpServer(
        @socket.Addr::parse("127.0.0.1:0"),
        reuse_addr=true,
      )
      let transcript : @test_support.TestSmtpTranscript = {
        lines: [],
        data: "",
      }
      group.spawn_bg(() => {
        @test_support.run_one_message_smtp_server(server, transcript)
      })
      let config = @transport.SmtpConfig::new(
        "127.0.0.1",
        server.addr.port(),
        auth=Plain("smtp-user", "smtp-password"),
      )
      assert_true(
        deliver_next_email(
          pool,
          "test-worker",
          Smtp(config~, from="noreply@example.com"),
        ),
      )
      assert_true(
        transcript.data.contains("Subject: Reset your Moonhub password"),
      )
      assert_true(transcript.data.contains("Reset code: "))
      pool.with_client(client => {
        let row = client.query_one("SELECT body, status FROM email_outbox")
        assert_eq((row.get_name("status") : String), "sent")
        assert_eq(
          (row.get_name("body") : String),
          "Password reset code removed after delivery.",
        )
      })
    })
  })
}

///|
async test "mail worker discards invalid reset mail while continuing to deliver ordinary messages" {
  for
    mutation in [
      "UPDATE password_reset SET expires_at = datetime('now', '-1 second')", "UPDATE password_reset SET used_at = datetime('now')",
      "UPDATE \"user\" SET status = 'disabled' WHERE id = 1", "UPDATE \"user\" SET email = 'other@example.com' WHERE id = 1",
      "DELETE FROM \"user\" WHERE id = 1",
    ] {
    @test_support.with_ssh_test_db(pool => {
      pool.with_client(client => {
        let _ = client.execute(
          "UPDATE \"user\" SET email = 'alice@example.com' WHERE id = 1",
        )
      })
      @identity.request_password_reset(pool, "alice@example.com")
      pool.with_client(client => {
        client.batch_execute(mutation)
        let _ = client.execute(
          "INSERT INTO email_outbox (to_email, subject, body) VALUES ('alice@example.com', 'Ordinary email', 'Unchanged')",
        )
      })
      let message = claim_next_email(pool, "test-worker").unwrap()
      assert_eq(message.subject, "Ordinary email")
      assert_eq(message.body, "Unchanged")
      mark_email_delivered(pool, message.id, "test-provider")
      assert_true(claim_next_email(pool, "test-worker") is None)
      pool.with_client(client => {
        let row = client.query_one(
          "SELECT body, status FROM email_outbox WHERE template = 'password_reset'",
        )
        assert_eq((row.get_name("status") : String), "failed")
        assert_eq(
          (row.get_name("body") : String),
          "Password reset code is no longer valid.",
        )
      })
    })
  }
}
