///|
let test_repo_root : String = "testdata/repos"

///|
let test_assets_root : String = "assets"

///|
let test_auth_name_key : String = "moonhub_test_root"

///|
let test_auth_password : String = "initialPassword123"

///|
let test_mail_outbox_dir : String = "_build/test_mail_outbox"

///|
let browser_app_module : @moonback.Module = Module(ctx => {
  let config = ctx.config()
  ctx.mount("/\{PUBLIC_ASSETS_OWNER}", App(assets_module, config~))
  ctx.mount(
    "/",
    App(
      Module(ctx => {
        let asset_path_map = load_entry_to_asset_path_map(assets_root(ctx))
        let root = repo_root(ctx)
        ctx.add_middleware(app_error_middleware(asset_path_map))
        ctx.use_(index_module(asset_path_map, _ => list_repositories(root)))
        ctx.use_(repo_browser_module(asset_path_map, (_, _) => ()))
      }),
      config~,
    ),
  )
})

///|
fn test_app_config(
  repo_root? : String = test_repo_root,
  assets_root? : String = test_assets_root,
) -> @moonback.Config {
  Config(custom=[
    @moonback.Config::custom(config_root, repo_root),
    @moonback.Config::custom(config_assets_root, assets_root),
  ])
}

///|
async test "initializes app module" {
  let app = @moonback.App(browser_app_module, config=test_app_config())
  defer app.close()
}

///|
test "assets is a reserved repository owner" {
  assert_true(valid_repo_owner("alice"))
  assert_true(!valid_repo_owner(PUBLIC_ASSETS_OWNER))
}

///|
async test "loads entry asset path map from vite manifest" {
  let asset_path_map = load_entry_to_asset_path_map(test_assets_root)
  assert_true(asset_path_map["src/app.css"].has_prefix("/assets/app_styles-"))
  assert_true(
    asset_path_map["src/custom-elements.tsx"].has_prefix(
      "/assets/custom-elements-",
    ),
  )
}

///|
test "public browser assets use immutable caching" {
  assert_eq(
    asset_cache_control("custom-elements.js"),
    "public, max-age=31536000, immutable",
  )
  assert_eq(
    asset_cache_control("custom-elements-Cba53Qon.js"),
    "public, max-age=31536000, immutable",
  )
}

///|
async test "mail transport defaults to file outbox without persisted settings" {
  with_ssh_test_db(pool => {
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
struct TestSmtpTranscript {
  lines : Array[String]
  mut data : String
}

///|
async fn run_one_message_smtp_server(
  server : @socket.TcpServer,
  transcript : TestSmtpTranscript,
) -> Unit {
  defer server.close()
  match @async.with_timeout_opt(5000, () => server.accept()) {
    Some((conn, _)) => {
      defer conn.close()
      conn.write("220 moonhub test smtp\r\n")
      let mut in_data = false
      for ;; {
        match conn.read_until("\r\n") {
          None => return
          Some(line) =>
            if in_data {
              if line == "." {
                in_data = false
                conn.write("250 queued test-message\r\n")
              } else {
                transcript.data = transcript.data + line + "\n"
              }
            } else {
              transcript.lines.push(line)
              if line.has_prefix("EHLO ") {
                conn.write("250-localhost\r\n250 AUTH PLAIN\r\n")
              } else if line.has_prefix("AUTH PLAIN ") {
                conn.write("235 authenticated\r\n")
              } else if line.has_prefix("MAIL FROM:") {
                conn.write("250 sender ok\r\n")
              } else if line.has_prefix("RCPT TO:") {
                conn.write("250 recipient ok\r\n")
              } else if line == "DATA" {
                conn.write("354 end with <CRLF>.<CRLF>\r\n")
                in_data = true
              } else if line == "QUIT" {
                conn.write("221 bye\r\n")
                return
              } else {
                conn.write("500 unsupported\r\n")
              }
            }
        }
      }
    }
    None => abort("smtp test server did not receive a connection")
  }
}

///|
async test "smtp transport delivers queued email through smtp" {
  @async.with_task_group(group => {
    let server = @socket.TcpServer::TcpServer(
      @socket.Addr::parse("127.0.0.1:0"),
      reuse_addr=true,
    )
    let port = server.addr.port()
    let transcript : TestSmtpTranscript = { lines: [], data: "", }
    group.spawn_bg(() => run_one_message_smtp_server(server, transcript))
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

///|
async fn rendered_blob_page(port : Int) -> String {
  let (response, body) = @http.get(
    "http://127.0.0.1:\{port}/alice/demo/blob/master/src/main.mbt",
  )
  assert_eq(response.code, 200)
  body.text()
}

///|
async test "serves repository paths from route params" {
  let app = @moonback.App(browser_app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = rendered_blob_page(port)
    assert_true(html.contains("println(&quot;hi&quot;)"))
  })
}

///|
async test "serves slash branches and tags in repository URLs" {
  with_git_test_repo(async fn(root, git_dir) {
    let branch = "yuxiang/regex-states-overflow-fallback"
    ignore(run_git(git_dir, ["update-ref", "refs/heads/\{branch}", "master"]))
    ignore(run_git(git_dir, ["update-ref", "refs/tags/release", "master"]))
    ignore(run_git(git_dir, ["update-ref", "refs/heads/release/v1", "master"]))
    ignore(run_git(git_dir, ["update-ref", "refs/tags/releases/v2", "master"]))
    let commit = run_git(git_dir, ["rev-parse", "master"]).trim().to_owned()
    let app = @moonback.App(
      browser_app_module,
      config=test_app_config(repo_root=root),
    )
    defer app.close()
    @async.with_task_group(group => {
      let server = @moonback.listen(port=0)
      let task = group.spawn(() => app.serve(server))
      defer task.cancel()
      let port = server.addr.port()
      for rev in [branch, "release/v1", "releases/v2", "master", "HEAD", commit] {
        let (response, body) = http_get_path(
          port,
          "/alice/demo/blob/\{rev}/src/main.mbt",
        )
        assert_eq(response.code, 200, msg=body)
        assert_true(
          body.contains("<span data-file-name hidden>src/main.mbt</span>"),
        )
        assert_true(body.contains("println(&quot;hi&quot;)"))
        let (response, body) = http_get_path(port, "/alice/demo/tree/\{rev}")
        assert_eq(response.code, 200, msg=body)
        assert_true(body.contains("/alice/demo/tree/\{rev}/src"))
        let (response, body) = http_get_path(
          port,
          "/alice/demo/tree/\{rev}/src",
        )
        assert_eq(response.code, 200, msg=body)
        assert_true(body.contains("/alice/demo/blob/\{rev}/src/main.mbt"))
      }
      let (response, body) = http_get_path(port, "/alice/demo?rev=\{branch}")
      assert_eq(response.code, 200, msg=body)
      assert_true(body.contains("/alice/demo/blob/\{branch}/README.md"))
      let (response, body) = http_get_path(
        port,
        "/alice/demo/commits?rev=\{branch}",
      )
      assert_eq(response.code, 200, msg=body)
      assert_true(body.contains("initial fixture commit"))
      let (response, _) = http_get_path(port, "/alice/demo?rev=missing/branch")
      assert_eq(response.code, 404)
      let (response, _) = http_get_path(
        port,
        "/alice/demo/blob/\{branch}/missing.mbt",
      )
      assert_eq(response.code, 404)
      let (response, _) = http_get_path(port, "/alice/demo/blob/\{branch}")
      assert_eq(response.code, 404)
      let (response, _) = http_get_path(
        port,
        "/alice/demo/blob/\{branch}/../README.md",
      )
      assert_eq(response.code, 400)
      let (response, _) = http_get_path(
        port, "/alice/demo/blob/releases/v20/src/main.mbt",
      )
      assert_eq(response.code, 404)
      ignore(run_git(git_dir, ["symbolic-ref", "HEAD", "refs/heads/\{branch}"]))
      let (response, body) = http_get_path(port, "/alice/demo")
      assert_eq(response.code, 200, msg=body)
      assert_true(body.contains("/alice/demo/blob/\{branch}/README.md"))
    })
  })
}

///|
fn extract_attr(html : String, marker : String, attr : String) -> String {
  match html.find(marker) {
    Some(marker_start) => {
      let attr_start = marker_start + html[marker_start:].find(attr).unwrap()
      let value_start = attr_start + attr.length()
      let value_end = value_start + html[value_start:].find("\"").unwrap()
      html[value_start:value_end].to_owned()
    }
    None => abort("missing marker")
  }
}

///|
async fn rendered_commit_page(port : Int) -> String {
  let commits = list_commits("\{test_repo_root}/alice/demo.git", "master")
  let (response, body) = @http.get(
    "http://127.0.0.1:\{port}/alice/demo/commit/\{commits[0].hash}",
  )
  assert_eq(response.code, 200)
  body.text()
}

///|
async fn http_head(port : Int, path : String) -> @http.Response {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  client..request(Head, path).end_request()
}

///|
async fn http_get_path(port : Int, path : String) -> (@http.Response, String) {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let response = client..request(Get, path).end_request()
  (response, client.read_all().text())
}

///|
async fn http_get_path_with_cookie(
  port : Int,
  path : String,
  cookie : @http.Cookie,
) -> (@http.Response, String) {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let response = client.get(path, extra_headers={
    "Cookie": "\{cookie.name}=\{cookie.value}",
  })
  (response, client.read_all().text())
}

///|
async fn http_post_path_with_cookie(
  port : Int,
  path : String,
  body : String,
  cookie : @http.Cookie,
) -> (@http.Response, String) {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let response = client.post(path, body, extra_headers={
    "Content-Type": "application/x-www-form-urlencoded",
    "Cookie": "\{cookie.name}=\{cookie.value}",
  })
  (response, client.read_all().text())
}

///|
async fn login_test_user(
  port : Int,
  name_key : String,
  password : String,
) -> @http.Cookie {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let response = client.post(
    "/login",
    "name_key=\{name_key}&password=\{password}",
    extra_headers={ "Content-Type": "application/x-www-form-urlencoded" },
  )
  client.skip_response_body()
  assert_eq(response.code, 303)
  match response.cookies.get(0) {
    Some(cookie) => cookie
    None => abort("missing session cookie")
  }
}

///|
fn reset_auth_test_data(pool : Database) -> Unit raise {
  pool.with_client(client => {
    let _ = client.execute(
      (
        #|DELETE FROM team
        #|WHERE name_key IN ('moonhub_test_root', 'moonhub_test_team')
      ),
    )
    let _ = client.execute(
      (
        #|DELETE FROM "user"
        #|WHERE name_key IN ('moonhub_test_root', 'moonhub_invited_admin')
      ),
    )
    let _ = client.execute(
      (
        #|DELETE FROM invitation
        #|WHERE name_key IN ('moonhub_test_root', 'moonhub_invited_admin')
      ),
    )
    let _ = client.execute(
      (
        #|DELETE FROM email_outbox
        #|WHERE to_email IN ('invited-admin@example.com')
      ),
    )
  })
}

///|
async fn with_production_test_app(
  f : async (@moonback.App, Int, Database) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group) catch {
      err => abort("database open failed: \{err}")
    }
    defer pool.close()
    initialize_db(pool) catch {
      err => abort("database initialization failed: \{err}")
    }
    reset_auth_test_data(pool) catch {
      err => abort("reset auth test data failed: \{err}")
    }
    ensure_root_invitation(pool, {
      name_key: test_auth_name_key,
      initial_password: test_auth_password,
    }) catch {
      err => abort("ensure root invitation failed: \{err}")
    }
    let app = @moonback.App(
      app_module,
      config=Config(custom=[
        @moonback.Config::custom(config_root, test_repo_root),
        @moonback.Config::custom(config_assets_root, test_assets_root),
        @moonback.Config::custom(config_db_pool, pool),
      ]),
    )
    defer app.close()
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    f(app, server.addr.port(), pool) catch {
      err => abort("production app test failed: \{err}")
    }
  })
}

///|
fn invited_admin_password_from_outbox(pool : Database) -> String raise {
  let body : String = pool.with_client(client => {
    let row = client.query_one(
      (
        #|SELECT body
        #|FROM email_outbox
        #|WHERE to_email = 'invited-admin@example.com'
        #|ORDER BY id DESC
        #|LIMIT 1
      ),
    )
    row.get_name("body")
  })
  let marker = "One-time password: "
  let start = body.find(marker).unwrap() + marker.length()
  let end = match body[start:].find("\n") {
    Some(offset) => start + offset
    None => body.length()
  }
  body[start:end].to_owned()
}

///|
fn latest_invited_admin_outbox_id(pool : Database) -> Int64 raise {
  pool.with_client(client => {
    let row = client.query_one(
      (
        #|SELECT id
        #|FROM email_outbox
        #|WHERE to_email = 'invited-admin@example.com'
        #|ORDER BY id DESC
        #|LIMIT 1
      ),
    )
    row.get_name("id")
  })
}

///|
async test "invalid route params return bad request" {
  let app = @moonback.App(browser_app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let (response, body) = http_get_path(port, "/alice/demo/tree/.")
    assert_eq(response.code, 400)
    assert_true(body.contains("invalid revision"))
  })
}

///|
async test "root invitation creates team and revoked team invitation cannot sign in" {
  with_production_test_app(async fn(_app, port, pool) {
    let root_invitation_cookie = login_test_user(
      port, test_auth_name_key, test_auth_password,
    )
    let (change_response, _) = http_post_path_with_cookie(
      port, "/change-password", "new_password=changedPassword123&confirm_password=changedPassword123",
      root_invitation_cookie,
    )
    assert_eq(change_response.code, 303)

    let root_cookie = login_test_user(
      port, test_auth_name_key, "changedPassword123",
    )
    let (teams_response, teams_body) = http_get_path_with_cookie(
      port, "/teams", root_cookie,
    )
    assert_eq(teams_response.code, 200)
    assert_true(teams_body.contains("New team"))

    let (create_response, _) = http_post_path_with_cookie(
      port, "/teams", "name_key=moonhub_test_team&display_name=Moonhub%20Test%20Team",
      root_cookie,
    )
    assert_eq(create_response.code, 303)
    assert_true(
      create_response.headers.get("location")
      is Some("/teams/moonhub_test_team"),
    )

    let invite_body = "email=invited-admin%40example.com&name_key=moonhub_invited_admin&display_name=Invited%20Admin&role=admin"
    let (invite_response, _) = http_post_path_with_cookie(
      port, "/teams/moonhub_test_team/invitations", invite_body, root_cookie,
    )
    assert_eq(invite_response.code, 303)
    let (pending_page_response, pending_page_body) = http_get_path_with_cookie(
      port, "/teams/moonhub_test_team", root_cookie,
    )
    assert_eq(pending_page_response.code, 200)
    assert_true(pending_page_body.contains("<th>Delivery</th>"))
    assert_true(pending_page_body.contains("<td>pending</td><td>"))
    let one_time_password = invited_admin_password_from_outbox(pool)
    let outbox_id = latest_invited_admin_outbox_id(pool)
    assert_true(
      deliver_next_email(
        pool,
        "test-worker",
        File(outbox_dir=test_mail_outbox_dir),
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
    let mail_text = @fs.read_file("\{test_mail_outbox_dir}/\{outbox_id}.eml").text()
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
    let (_, failed_page_body) = http_get_path_with_cookie(
      port, "/teams/moonhub_test_team", root_cookie,
    )
    assert_true(failed_page_body.contains(">Resend</button>"))
    let (resend_response, _) = http_post_path_with_cookie(
      port,
      "/teams/moonhub_test_team/invitations/\{invitation_id.to_string()}/resend",
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
    assert_eq((resent_row.get_name("attempt_count") : Int), 0)
    assert_true((resent_row.get_name("last_error") : String?) is None)
    assert_true((resent_row.get_name("provider_message_id") : String?) is None)
    assert_true((resent_row.get_name("sent_at") : String?) is None)
    assert_true(
      deliver_next_email(
        pool,
        "test-worker",
        File(outbox_dir=test_mail_outbox_dir),
      ),
    )
    let (sent_page_response, sent_page_body) = http_get_path_with_cookie(
      port, "/teams/moonhub_test_team", root_cookie,
    )
    assert_eq(sent_page_response.code, 200)
    assert_true(sent_page_body.contains("<td>sent<div class=\"muted\">"))

    let (revoke_response, _) = http_post_path_with_cookie(
      port,
      "/teams/moonhub_test_team/invitations/\{invitation_id.to_string()}/revoke",
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
      "/login",
      "name_key=moonhub_invited_admin&password=\{one_time_password}",
      extra_headers={ "Content-Type": "application/x-www-form-urlencoded" },
    )
    client.skip_response_body()
    assert_eq(denied.code, 401)
  })
}

///|
async test "missing repositories return not found" {
  let app = @moonback.App(browser_app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let (response, body) = http_get_path(port, "/alice/missing")
    assert_eq(response.code, 404)
    assert_true(body.contains("repository not found"))
  })
}

///|
async test "missing git resources return not found" {
  let app = @moonback.App(browser_app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let (blob_response, blob_body) = http_get_path(
      port, "/alice/demo/blob/master/missing.mbt",
    )
    assert_eq(blob_response.code, 404)
    assert_true(blob_body.contains("file not found"))
    let (tree_response, tree_body) = http_get_path(
      port, "/alice/demo/tree/master/missing",
    )
    assert_eq(tree_response.code, 404)
    assert_true(tree_body.contains("tree not found"))
    let (commit_response, commit_body) = http_get_path(
      port, "/alice/demo/commit/not-a-real-commit",
    )
    assert_eq(commit_response.code, 404)
    assert_true(commit_body.contains("commit not found"))
  })
}

///|
async test "serves browser assets from mounted assets app" {
  let app = @moonback.App(browser_app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = rendered_commit_page(port)
    let stylesheet_path = extract_attr(
      html, "<link rel=\"stylesheet\"", "href=\"",
    )
    let (stylesheet_response, stylesheet_body) = @http.get(
      "http://127.0.0.1:\{port}\{stylesheet_path}",
    )
    assert_eq(stylesheet_response.code, 200)
    assert_true(
      stylesheet_response.headers.get("content-type")
      is Some("text/css; charset=utf-8"),
    )
    assert_true(stylesheet_body.text().contains(".site-header"))
    let asset_path = extract_attr(html, "<script type=\"module\"", "src=\"")
    let (response, body) = @http.get("http://127.0.0.1:\{port}\{asset_path}")
    assert_eq(response.code, 200)
    assert_true(
      response.headers.get("content-type")
      is Some("text/javascript; charset=utf-8"),
    )
    assert_true(
      response.headers.get("cache-control")
      is Some("public, max-age=31536000, immutable"),
    )
    assert_true(body.text().contains("moonhub-commit-diff"))
    assert_true(body.text().contains("moonhub-file-view"))
  })
}

///|
async test "does not serve vite manifest as public asset" {
  let app = @moonback.App(browser_app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let (get_response, _) = @http.get(
      "http://127.0.0.1:\{port}/assets/.vite/manifest.json",
    )
    assert_eq(get_response.code, 404)
    let head_response = http_head(port, "/assets/.vite/manifest.json")
    assert_eq(head_response.code, 404)
  })
}

///|
async test "serves browser assets from configured absolute path" {
  let repo_root = @fs.realpath(test_repo_root)
  let assets_root = @fs.realpath(test_assets_root)
  let app = @moonback.App(
    browser_app_module,
    config=test_app_config(repo_root~, assets_root~),
  )
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = rendered_commit_page(port)
    assert_true(html.contains("/assets/custom-elements-"))
    let asset_path = extract_attr(html, "<script type=\"module\"", "src=\"")
    let (response, body) = @http.get("http://127.0.0.1:\{port}\{asset_path}")
    assert_eq(response.code, 200)
    assert_true(body.text().contains("moonhub-file-view"))
  })
}

///|
async test "blob page includes rich file custom element" {
  let app = @moonback.App(browser_app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = rendered_blob_page(port)
    assert_true(html.contains("https://fonts.googleapis.com"))
    assert_true(html.contains("family=M+PLUS+Code+Latin"))
    assert_true(html.contains("rel=\"modulepreload\""))
    assert_true(html.contains("blocking=\"render\""))
    assert_true(html.contains("fetchpriority=\"high\""))
    assert_true(html.contains("/assets/custom-elements-"))
    assert_true(html.contains("<moonhub-file-view>"))
    assert_true(
      html.contains("<span data-file-name hidden>src/main.mbt</span>"),
    )
    assert_true(html.contains("<pre data-file-content>"))
  })
}

///|
async test "commit page includes rich diff custom element" {
  let app = @moonback.App(browser_app_module, config=test_app_config())
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    defer task.cancel()
    let port = server.addr.port()
    let html = rendered_commit_page(port)
    assert_true(html.contains("https://fonts.googleapis.com"))
    assert_true(html.contains("family=M+PLUS+Code+Latin"))
    assert_true(html.contains("rel=\"modulepreload\""))
    assert_true(html.contains("blocking=\"render\""))
    assert_true(html.contains("fetchpriority=\"high\""))
    assert_true(html.contains("/assets/custom-elements-"))
    assert_true(html.contains("<moonhub-commit-diff>"))
    assert_true(html.contains("<pre data-patch>diff --git "))
    assert_true(!html.contains("files changed"))
  })
}
