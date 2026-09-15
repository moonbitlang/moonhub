///|
fn smtp_settings_form(csrf : String, password : String) -> String {
  "csrf_token=\{csrf}&transport=smtp&smtp_host=smtp.example.com&smtp_port=465&smtp_security=tls&smtp_auth=login&smtp_username=mailer%40example.com&smtp_password=\{password}&smtp_tls_trust=system&smtp_tls_root_cert_file=&smtp_helo_name=moonhub.example.com&smtp_from=noreply%40example.com"
}

///|
async test "site administrators configure SMTP settings from the settings page" {
  with_ssh_settings_app((port, pool, alice, _, admin) => {
    let (page, body) = http_get_path_with_cookie(
      port, "/admin/settings/ssh", admin,
    )
    assert_eq(page.code, 200)
    assert_true(body.contains("Email delivery"))
    let csrf = extract_attr(body, "action=\"/admin/settings/mail\"", "value=\"")
    let (denied, _) = http_post_path_with_cookie(
      port,
      "/admin/settings/mail",
      smtp_settings_form(csrf, "secret"),
      alice,
    )
    assert_eq(denied.code, 403)
    let (invalid, invalid_body) = http_post_path_with_cookie(
      port,
      "/admin/settings/mail",
      smtp_settings_form(csrf, ""),
      admin,
    )
    assert_eq(invalid.code, 400)
    assert_true(invalid_body.contains("SMTP password is required"))
    assert_true(invalid_body.contains("value=\"smtp.example.com\""))
    let (saved, _) = http_post_path_with_cookie(
      port,
      "/admin/settings/mail",
      smtp_settings_form(csrf, "secret"),
      admin,
    )
    assert_eq(saved.code, 303)
    assert_true(
      saved.headers.get("location") is Some("/admin/settings/ssh?saved_mail=1"),
    )
    let settings = load_mail_settings(pool)
    assert_eq(settings.transport, "smtp")
    assert_eq(settings.smtp.host, "smtp.example.com")
    assert_eq(settings.smtp.port, 465)
    assert_eq(settings.smtp.password, "secret")
    match mail_transport_from_db(pool) {
      File(_) => abort("expected SMTP mail transport")
      Smtp(config~, from~) => {
        assert_eq(config.host, "smtp.example.com")
        assert_eq(config.port, 465)
        assert_true(config.security == Tls)
        assert_true(config.auth == Login("mailer@example.com", "secret"))
        assert_eq(config.hello_name, "moonhub.example.com")
        assert_true(config.tls_trust == SystemRoot)
        assert_eq(from, "noreply@example.com")
      }
    }
    let (saved_again, _) = http_post_path_with_cookie(
      port,
      "/admin/settings/mail",
      smtp_settings_form(csrf, ""),
      admin,
    )
    assert_eq(saved_again.code, 303)
    assert_eq(load_mail_settings(pool).smtp.password, "secret")
    let (_, after) = http_get_path_with_cookie(
      port, "/admin/settings/ssh?saved_mail=1", admin,
    )
    assert_true(!after.contains("secret"))
    assert_true(after.contains("Password is configured"))
    assert_eq(extract_attr(after, "id=\"smtp-password\"", "value=\""), "")
  })
}

///|
async test "SMTP settings enforce CSRF and reject invalid fields without storing or exposing passwords" {
  with_ssh_settings_app((port, pool, alice, _, admin) => {
    let (_, body) = http_get_path_with_cookie(
      port, "/admin/settings/ssh", admin,
    )
    let token = extract_attr(
      body, "action=\"/admin/settings/mail\"", "value=\"",
    )
    let wrong_scope = extract_attr(
      body, "action=\"/admin/settings/ssh\"", "value=\"",
    )
    for
      csrf in [
        "",
        "forged",
        wrong_scope,
        form_csrf_token(alice.value, "site-mail-settings"),
      ] {
      let (response, _) = http_post_path_with_cookie(
        port,
        "/admin/settings/mail",
        smtp_settings_form(csrf, "hidden-password"),
        admin,
      )
      assert_eq(response.code, 403)
    }
    let base = smtp_settings_form(token, "hidden-password")
    for
      (field, invalid) in [
        ("smtp_port=465", "smtp_port=0"),
        ("smtp_port=465", "smtp_port=65536"),
        ("smtp_port=465", "smtp_port=abc"),
        ("smtp_host=smtp.example.com", "smtp_host="),
        ("smtp_host=smtp.example.com", "smtp_host=smtp.example.com%0D%0AQUIT"),
        ("smtp_helo_name=moonhub.example.com", "smtp_helo_name=host%0D%0AQUIT"),
        ("smtp_auth=login", "smtp_auth=invalid"),
        ("smtp_from=noreply%40example.com", "smtp_from=invalid"),
        ("smtp_tls_trust=system", "smtp_tls_trust=custom"),
        ("smtp_username=mailer%40example.com", "smtp_username="),
        ("transport=smtp", "transport=invalid"),
      ] {
      let (response, html) = http_post_path_with_cookie(
        port,
        "/admin/settings/mail",
        base.replace(old=field, new=invalid),
        admin,
      )
      assert_eq(response.code, 400)
      assert_true(response.headers.get("cache-control") is Some("no-store"))
      assert_true(!html.contains("hidden-password"))
      assert_eq(load_mail_settings(pool).transport, "file")
    }
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let response = client.post("/admin/settings/mail", base, extra_headers={
      "Cookie": "\{admin.name}=\{admin.value}",
      "Sec-Fetch-Site": "cross-site",
      "Content-Type": "application/x-www-form-urlencoded",
    })
    client.skip_response_body()
    assert_eq(response.code, 403)
    assert_eq(load_mail_settings(pool).transport, "file")
  })
}

///|
async test "SMTP settings preserve exact passwords, support no authentication, and ignore environment overrides" {
  with_ssh_test_db(pool => {
    let actor = active_user_by_name(pool, "admin")
    let form = parse_form(smtp_settings_form("", "%20secret%20"))
    save_mail_settings(pool, actor, form, load_mail_settings(pool))
    assert_eq(load_mail_settings(pool).smtp.password, " secret ")
    form["smtp_password"] = "replacement"
    save_mail_settings(pool, actor, form, load_mail_settings(pool))
    assert_eq(load_mail_settings(pool).smtp.password, "replacement")
    let variables = ["MAIL_TRANSPORT", "SMTP_HOST", "SMTP_PASSWORD"]
    let previous = variables.map(name => (name, @env.get_env_var(name)))
    defer (for (name, value) in previous {
      match value {
        Some(value) => @env.set_env_var(name, value)
        None => @env.unset_env_var(name)
      }
    })
    @env.set_env_var("MAIL_TRANSPORT", "file")
    @env.set_env_var("SMTP_HOST", "ignored.invalid")
    @env.set_env_var("SMTP_PASSWORD", "ignored-password")
    match mail_transport_from_db(pool) {
      Smtp(config~, ..) => {
        assert_eq(config.host, "smtp.example.com")
        assert_true(config.auth == Login("mailer@example.com", "replacement"))
      }
      File(_) => fail("environment overrode site settings")
    }
    form["smtp_auth"] = "none"
    form["smtp_username"] = ""
    form["smtp_password"] = ""
    save_mail_settings(pool, actor, form, load_mail_settings(pool))
    assert_eq(load_mail_settings(pool).smtp.password, "")
    match mail_transport_from_db(pool) {
      Smtp(config~, ..) => assert_true(config.auth == None)
      File(_) => fail("expected unauthenticated SMTP")
    }
    form["transport"] = "file"
    save_mail_settings(pool, actor, form, load_mail_settings(pool))
    @env.set_env_var("MAIL_TRANSPORT", "smtp")
    assert_true(mail_transport_from_db(pool) is File(_))
    initialize_db(pool)
    assert_eq(load_mail_settings(pool).transport, "file")
  })
}

///|
async test "mail settings migration preserves version four SSH settings and is repeatable" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    for
      path in [
        "db/base.sql", "db/migrations/001_ssh_keys.sql", "db/migrations/002_repository_jobs.sql",
        "db/migrations/003_ssh_addresses.sql", "db/migrations/004_merge_requests.sql",
      ] {
      let sql = @fs.read_file(path).text()
      pool.with_client(client => client.batch_execute(sql))
    }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO site_settings (id, ssh_public_host, ssh_public_port) VALUES (1, 'git.example.com', 2222);
          #|PRAGMA user_version = 4;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    assert_eq(
      effective_ssh_endpoint(pool, no_ssh_address_config).unwrap().authority(),
      "git.example.com:2222",
    )
    assert_eq(load_mail_settings(pool).transport, "file")
    assert_eq(load_mail_settings(pool).smtp.port, 587)
    pool.with_client(client => {
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
    })
  })
}

///|
async test "running mail worker picks up persisted SMTP changes for subsequent messages" {
  with_ssh_test_db(pool => {
    @async.with_task_group(group => {
      let worker = group.spawn(() => run_mail_worker(pool, "smtp-settings-test"))
      defer worker.cancel()
      @async.sleep(10)
      let actor = active_user_by_name(pool, "admin")
      for index in [1, 2] {
        let server = @socket.TcpServer::TcpServer(
          @socket.Addr::parse("127.0.0.1:0"),
          reuse_addr=true,
        )
        let transcript : TestSmtpTranscript = { lines: [], data: "", }
        let smtp = group.spawn(() => {
          run_one_message_smtp_server(server, transcript)
        })
        let form = parse_form(smtp_settings_form("", "password"))
        form["smtp_host"] = "127.0.0.1"
        form["smtp_port"] = server.addr.port().to_string()
        form["smtp_security"] = "plain"
        form["smtp_auth"] = "plain"
        form["smtp_from"] = "sender\{index}@example.com"
        save_mail_settings(pool, actor, form, load_mail_settings(pool))
        pool.with_client(client => {
          let _ = client.execute(
            "INSERT INTO email_outbox (to_email, subject, body) VALUES ('reader@example.com', 'Live SMTP', 'Invitation body')",
          )
        })
        smtp.wait()
        assert_true(
          transcript.lines.contains("MAIL FROM:<sender\{index}@example.com>"),
        )
        assert_true(transcript.data.contains("Invitation body"))
        pool.with_client(client => {
          assert_eq(
            (
              client
              .query_one(
                "SELECT count(*) AS count FROM email_outbox WHERE status = 'sent'",
              )
              .get_name("count") : Int64),
            index.to_int64(),
          )
        })
      }
    })
  })
}

///|
async test "SMTP settings reject invalid security and TLS trust values" {
  with_ssh_settings_app((port, _, _, _, admin) => {
    let (_, body) = http_get_path_with_cookie(
      port, "/admin/settings/ssh", admin,
    )
    let csrf = extract_attr(body, "action=\"/admin/settings/mail\"", "value=\"")
    let base = smtp_settings_form(csrf, "secret")
    let (invalid_security, _) = http_post_path_with_cookie(
      port,
      "/admin/settings/mail",
      base.replace(old="smtp_security=tls", new="smtp_security=invalid"),
      admin,
    )
    assert_eq(invalid_security.code, 400)
    let (invalid_trust, _) = http_post_path_with_cookie(
      port,
      "/admin/settings/mail",
      base.replace(old="smtp_tls_trust=system", new="smtp_tls_trust=invalid"),
      admin,
    )
    assert_eq(invalid_trust.code, 400)
  })
}
