///|
async test "mail transport defaults to file outbox without persisted settings" {
  @test_support.with_ssh_test_db(pool => {
    match mail_transport_from_db(pool) {
      File(outbox_dir~) =>
        assert_eq(
          outbox_dir,
          @env.get_env_var("MAIL_OUTBOX_DIR").unwrap_or(default_mail_outbox_dir),
        )
      Smtp(_) => abort("expected file mail transport")
    }
  })
}

///|
async test "smtp transport delivers queued email through smtp" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer::TcpServer(
      @socket.Addr::parse("127.0.0.1:0"),
      reuse_addr=true,
    )
    let port = server.addr.port()
    let transcript : @test_support.TestSmtpTranscript = { lines: [], data: "", }
    group.spawn_bg(() => {
      @test_support.run_one_message_smtp_server(server, transcript)
    })
    let config = @transport.SmtpConfig::new(
      "127.0.0.1",
      port,
      auth=Plain("smtp-user", "smtp-password"),
    )
    let provider_message_id = deliver_email_to_smtp(
      config,
      "noreply@example.com",
      {
        id: 42L,
        to_email: "reader@example.com",
        subject: "SMTP invite",
        body: "Invitation body",
      },
    )
    assert_eq(provider_message_id, "smtp: 250 queued test-message")
    assert_true(transcript.lines[0] == "EHLO localhost")
    assert_true(transcript.lines[1].has_prefix("AUTH PLAIN "))
    assert_true(transcript.lines[2] == "MAIL FROM:<noreply@example.com>")
    assert_true(transcript.lines[3] == "RCPT TO:<reader@example.com>")
    assert_true(transcript.lines[4] == "DATA")
    assert_true(transcript.data.contains("Subject: SMTP invite"))
    assert_true(transcript.data.contains("Invitation body"))
  })
}
