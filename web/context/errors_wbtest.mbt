///|
async test "HTTP error boundary hides internal diagnostics and preserves public errors" {
  let assets = @web_assets.load_entry_to_asset_path_map(
    @web_testkit.test_assets_root,
  )
  let app = @moonback.App(
    Module(ctx => {
      ctx.add_middleware(app_error_middleware(assets))
      ctx.get("/:kind", async fn(req, res) {
        match required_param(req, "kind", "kind") {
          "connect" =>
            raise @moondb.ConnectError(@web_testkit.private_error_test_detail)
          "query" =>
            raise @moondb.QueryError(@web_testkit.private_error_test_detail)
          "type" =>
            raise @moondb.TypeError(@web_testkit.private_error_test_detail)
          "closed" => raise @moondb.Closed
          "git" =>
            ignore(
              @gitops.merge_git("/private-diagnostic-sentinel/missing.git", [
                "status",
              ]),
            )
          "command" =>
            raise @gitops.GitCommandFailed(
              code=128,
              output=@web_testkit.private_error_test_detail,
            )
          "filesystem" =>
            ignore(@fs.read_file("/private-diagnostic-sentinel/missing"))
          "unknown" => fail(@web_testkit.private_error_test_detail)
          "bad-request" => raise @domain.BadRequest(message="invalid input")
          "unauthorized" => raise @domain.Unauthorized(message="login required")
          "forbidden" => raise @domain.Forbidden(message="access denied")
          "not-found" => raise @domain.NotFound(message="resource not found")
          "git-validation" => ignore(@gitops.branch_sha("", ""))
          "committed" => {
            res.send_text("already sent")
            raise @moondb.QueryError(@web_testkit.private_error_test_detail)
          }
          _ => res.send_text("healthy")
        }
      })
    }),
  )
  defer app.close()
  @async.with_task_group(group => {
    let listener = @moonback.listen(port=0)
    let server = group.spawn(() => app.serve(listener))
    defer server.cancel()
    let port = listener.addr.port()
    for
      kind in [
        "connect", "query", "type", "closed", "git", "command", "filesystem", "unknown",
      ] {
      let (response, body) = @web_testkit.http_get_path(port, "/\{kind}")
      assert_eq(response.code, 500, msg=kind)
      assert_true(body.contains(@domain.internal_error_message), msg=kind)
      assert_true(!body.contains("private-diagnostic-sentinel"), msg=kind)
      assert_true(!body.contains("sql="), msg=kind)
      assert_true(!body.contains("database"), msg=kind)
      assert_true(response.headers.get("cache-control") is Some("no-store"))
    }
    for
      (kind, status, message) in [
        ("bad-request", 400, "invalid input"),
        ("unauthorized", 401, "login required"),
        ("forbidden", 403, "access denied"),
        ("not-found", 404, "resource not found"),
        ("git-validation", 400, "invalid branch name"),
      ] {
      let (response, body) = @web_testkit.http_get_path(port, "/\{kind}")
      assert_eq(response.code, status)
      assert_true(body.contains(message))
      assert_true(response.headers.get("cache-control") is Some("no-store"))
    }
    let (response, body) = @web_testkit.http_get_path(port, "/committed")
    assert_eq(response.code, 200)
    assert_eq(body, "already sent")
    let (response, body) = @web_testkit.http_get_path(port, "/healthy")
    assert_eq(response.code, 200)
    assert_eq(body, "healthy")
  })
}

///|
async test "Git execution failures are not public validation errors" {
  try
    @gitops.merge_git("/private-diagnostic-sentinel/missing.git", ["status"])
  catch {
    @gitops.InternalFailure(details~) =>
      assert_true(details.contains("private-diagnostic-sentinel"))
    err => raise err
  } noraise {
    _ => fail("expected an internal Git failure")
  }
}

///|
async test "legacy repository and merge diagnostics are never rendered" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
    let repo = @repository.enqueue_repository(
      pool, root, actor, team, "failed", "private", "",
    )
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository_job SET status = 'failed', last_error = ?",
        params=[@web_testkit.private_error_test_detail],
      )
    })
    for suffix in ["status", "discard"] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port,
        "/alice/-/repositories/\{repo.name}/\{suffix}",
        cookie,
      )
      assert_eq(response.code, 200)
      assert_true(body.contains(@domain.repository_error_message))
      assert_true(!body.contains("private-diagnostic-sentinel"))
    }
    assert_eq(
      @repository.require_repository_job(pool, team, "failed").last_error,
      Some(@web_testkit.private_error_test_detail),
    )
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let git_dir = repo.git_dir(root)
    let parent = @gitops.branch_sha(git_dir, "master")
    ignore(
      @test_support.merge_test_commit(git_dir, "feature", parent, "feature\n"),
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, git_dir, actor, "Failure audit", "", "feature", "master", false,
    )
    pool.with_client(client => {
      client.with_transaction(tx => {
        let _ = tx.execute(
          "INSERT INTO merge_job (merge_request_id, actor_id, version, status, last_error) VALUES (?, ?, ?, 'failed', ?)",
          params=[
            mr.id,
            actor.id,
            mr.version,
            @web_testkit.private_error_test_detail,
          ],
        )
        let _ = tx.execute(
          "UPDATE merge_revision SET block_reason = ? WHERE merge_request_id = ?",
          params=[@web_testkit.private_error_test_detail, mr.id],
        )
        let _ = tx.execute(
          "INSERT INTO merge_activity (merge_request_id, actor_id, kind, body, version) VALUES (?, ?, 'merge_failed', ?, ?)",
          params=[
            mr.id,
            actor.id,
            @web_testkit.private_error_test_detail,
            mr.version,
          ],
        )
      })
    })
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port,
      "/alice/demo/merge-requests/\{mr.number}",
      cookie,
    )
    assert_eq(response.code, 200)
    assert_true(body.contains(@domain.merge_error_message))
    assert_true(!body.contains("private-diagnostic-sentinel"))
    assert_true(!body.contains("password_hash"))
    assert_eq(
      @collaboration.merge_revision(pool, mr).block_reason,
      @domain.merge_error_message,
    )
  })
}

///|
test "stored merge blockers allow only known public messages" {
  assert_eq(@domain.public_merge_block_reason(""), "")
  let conflict = "branches have conflicts; resolve them locally and push the source branch"
  assert_eq(@domain.public_merge_block_reason(conflict), conflict)
  assert_eq(
    @domain.public_merge_block_reason(@web_testkit.private_error_test_detail),
    @domain.merge_error_message,
  )
  assert_eq(
    @domain.public_merge_block_reason(
      conflict + @web_testkit.private_error_test_detail,
    ),
    @domain.merge_error_message,
  )
  assert_eq(@domain.public_merge_job_error(""), "")
  let changed = "branches changed; reload and review the new version"
  assert_eq(@domain.public_merge_job_error(changed), changed)
  assert_eq(
    @domain.public_merge_job_error(@web_testkit.private_error_test_detail),
    @domain.merge_error_message,
  )
  assert_eq(
    @domain.public_merge_job_error(
      changed + @web_testkit.private_error_test_detail,
    ),
    @domain.merge_error_message,
  )
}

///|
async test "all form entry points reject oversized or invalid UTF8 bodies safely" {
  @web_testkit.with_ssh_settings_app((port, _, _, _, admin) => {
    for
      path in [
        "/-/login", "/-/change-password", "/-/teams", "/workshop/-/invitations",
      ] {
      for
        (body, message) in [
          (Bytes::make(65537, b'x'), "form is too large"),
          (b"\xff", "invalid form encoding"),
        ] {
        let client = @http.Client("http://127.0.0.1:\{port}")
        defer client.close()
        let response = client.post(path, body, extra_headers={
          "Content-Type": "application/x-www-form-urlencoded",
          "Cookie": "\{admin.name}=\{admin.value}",
        })
        let html = client.read_all().text()
        assert_eq(response.code, 400, msg=path)
        assert_true(html.contains(message), msg=path)
      }
    }
  })
}

///|
async test "duplicate teams preserve the original team and owner" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, admin) => {
    let form = "name_key=organization&display_name=Original"
    let (created, _) = @web_testkit.http_post_path_with_cookie(
      port, "/-/teams", form, admin,
    )
    assert_eq(created.code, 303)
    let (duplicate, body) = @web_testkit.http_post_path_with_cookie(
      port, "/-/teams", "name_key=organization&display_name=Changed", admin,
    )
    assert_eq(duplicate.code, 400)
    assert_true(body.contains("team already exists"))
    assert_true(!body.contains("sql="))
    let team = @identity.get_team_by_name_key(pool, "organization").unwrap()
    assert_eq(team.display_name, "Original")
    let members = @identity.list_team_members(pool, team)
    assert_eq(members.length(), 1)
    assert_eq(members[0].name_key, "admin")
    assert_eq(members[0].role, "owner")
  })
}
