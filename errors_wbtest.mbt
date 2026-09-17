///|
let private_error_test_detail : String = "private-diagnostic-sentinel: sql=SELECT password_hash FROM user; /srv/private/credentials"

///|
async test "HTTP error boundary hides internal diagnostics and preserves public errors" {
  let assets = load_entry_to_asset_path_map(test_assets_root)
  let app = @moonback.App(
    Module(ctx => {
      ctx.add_middleware(app_error_middleware(assets))
      ctx.get("/:kind", async fn(req, res) {
        match req.required_param("kind", "kind") {
          "connect" => raise @moondb.ConnectError(private_error_test_detail)
          "query" => raise @moondb.QueryError(private_error_test_detail)
          "type" => raise @moondb.TypeError(private_error_test_detail)
          "closed" => raise @moondb.Closed
          "git" =>
            ignore(
              @gitops.merge_git("/private-diagnostic-sentinel/missing.git", [
                "status",
              ]),
            )
          "command" =>
            raise GitCommandFailed(code=128, output=private_error_test_detail)
          "filesystem" =>
            ignore(@fs.read_file("/private-diagnostic-sentinel/missing"))
          "unknown" => fail(private_error_test_detail)
          "bad-request" => raise BadRequest(message="invalid input")
          "unauthorized" => raise Unauthorized(message="login required")
          "forbidden" => raise Forbidden(message="access denied")
          "not-found" => raise NotFound(message="resource not found")
          "git-validation" => ignore(@gitops.branch_sha("", ""))
          "committed" => {
            res.send_text("already sent")
            raise @moondb.QueryError(private_error_test_detail)
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
      let (response, body) = http_get_path(port, "/\{kind}")
      assert_eq(response.code, 500, msg=kind)
      assert_true(body.contains(internal_error_message), msg=kind)
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
      let (response, body) = http_get_path(port, "/\{kind}")
      assert_eq(response.code, status)
      assert_true(body.contains(message))
      assert_true(response.headers.get("cache-control") is Some("no-store"))
    }
    let (response, body) = http_get_path(port, "/committed")
    assert_eq(response.code, 200)
    assert_eq(body, "already sent")
    let (response, body) = http_get_path(port, "/healthy")
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
  with_repository_test_app((port, pool, root, cookie, _) => {
    let actor = active_user_by_name(pool, "alice")
    let team = get_team_by_name_key(pool, "alice").unwrap()
    let repo = enqueue_repository(
      pool, root, actor, team, "failed", "private", "",
    )
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository_job SET status = 'failed', last_error = ?",
        params=[private_error_test_detail],
      )
    })
    for suffix in ["status", "discard"] {
      let (response, body) = http_get_path_with_cookie(
        port,
        "/alice/-/repositories/\{repo.name}/\{suffix}",
        cookie,
      )
      assert_eq(response.code, 200)
      assert_true(body.contains(repository_error_message))
      assert_true(!body.contains("private-diagnostic-sentinel"))
    }
    assert_eq(
      require_repository_job(pool, team, "failed").last_error,
      Some(private_error_test_detail),
    )
    let repo : RepoId = { owner: "alice", name: "demo", }
    let scope = repository_scope(pool, actor, repo)
    let git_dir = repo.git_dir(root)
    let parent = @gitops.branch_sha(git_dir, "master")
    ignore(merge_test_commit(git_dir, "feature", parent, "feature\n"))
    let mr = create_merge_request(
      pool, scope, git_dir, actor, "Failure audit", "", "feature", "master", false,
    )
    pool.with_client(client => {
      client.with_transaction(tx => {
        let _ = tx.execute(
          "INSERT INTO merge_job (merge_request_id, actor_id, version, status, last_error) VALUES (?, ?, ?, 'failed', ?)",
          params=[mr.id, actor.id, mr.version, private_error_test_detail],
        )
        let _ = tx.execute(
          "UPDATE merge_revision SET block_reason = ? WHERE merge_request_id = ?",
          params=[private_error_test_detail, mr.id],
        )
        merge_activity(
          tx,
          mr,
          actor.id,
          "merge_failed",
          body=private_error_test_detail,
        )
      })
    })
    let (response, body) = http_get_path_with_cookie(
      port,
      "/alice/demo/merge-requests/\{mr.number}",
      cookie,
    )
    assert_eq(response.code, 200)
    assert_true(body.contains(merge_error_message))
    assert_true(!body.contains("private-diagnostic-sentinel"))
    assert_true(!body.contains("password_hash"))
    assert_eq(merge_revision(pool, mr).block_reason, merge_error_message)
  })
}

///|
test "stored merge blockers allow only known public messages" {
  assert_eq(public_merge_block_reason(""), "")
  let conflict = "branches have conflicts; resolve them locally and push the source branch"
  assert_eq(public_merge_block_reason(conflict), conflict)
  assert_eq(
    public_merge_block_reason(private_error_test_detail),
    merge_error_message,
  )
  assert_eq(
    public_merge_block_reason(conflict + private_error_test_detail),
    merge_error_message,
  )
  assert_eq(public_merge_job_error(""), "")
  let changed = "branches changed; reload and review the new version"
  assert_eq(public_merge_job_error(changed), changed)
  assert_eq(
    public_merge_job_error(private_error_test_detail),
    merge_error_message,
  )
  assert_eq(
    public_merge_job_error(changed + private_error_test_detail),
    merge_error_message,
  )
}

///|
async test "all form entry points reject oversized or invalid UTF8 bodies safely" {
  with_ssh_settings_app((port, _, _, _, admin) => {
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
  with_ssh_settings_app((port, pool, _, _, admin) => {
    let form = "name_key=organization&display_name=Original"
    let (created, _) = http_post_path_with_cookie(port, "/-/teams", form, admin)
    assert_eq(created.code, 303)
    let (duplicate, body) = http_post_path_with_cookie(
      port, "/-/teams", "name_key=organization&display_name=Changed", admin,
    )
    assert_eq(duplicate.code, 400)
    assert_true(body.contains("team already exists"))
    assert_true(!body.contains("sql="))
    let team = get_team_by_name_key(pool, "organization").unwrap()
    assert_eq(team.display_name, "Original")
    let members = list_team_members(pool, team)
    assert_eq(members.length(), 1)
    assert_eq(members[0].name_key, "admin")
    assert_eq(members[0].role, "owner")
  })
}
