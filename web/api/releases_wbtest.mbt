///|
async test "release REST authorization rejects wrong scopes and origin configuration before mutations" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let write = @identity.create_access_token(
      pool, alice, "release", "write", 1,
    )
    let read = @identity.create_access_token(
      pool, alice, "release-read", "read", 1,
    )
    let outsider = @identity.create_access_token(
      pool, bob, "outside", "write", 1,
    )
    let sha = @gitops.branch_sha(root + "/alice/demo.git", "master")
    let route = "/repos/alice/demo/releases"
    let body : Json = {
      "tag_name": "v1.2.3",
      "target_commitish": sha,
      "name": "Version <script>",
      "body": "notes",
      "draft": true,
    }
    assert_eq(api_test_request(port, route, read, Some(body)).0, 403)
    assert_eq(api_test_request(port, route, outsider, Some(body)).0, 404)
    let (code, release) = api_test_request(port, route, write, Some(body))
    assert_eq(code, 201)
    assert_true(
      release
      is {
        "draft": True,
        "target_commitish": String(target),
        "assets": Array(items),
        ..
      } &&
      target == sha &&
      items.is_empty(),
    )
    assert_eq(api_test_request(port, route, write, Some(body)).0, 409)
  })
}

///|
async test "real gh release commands create replace download publish and paginate through MoonHub" {
  guard @env.get_env_var("MOONHUB_RELEASE_GH") == Some("1") else { return }
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let token = @identity.create_access_token(
      pool, alice, "gh release smoke", "write", 1,
    )
    let sha = @gitops.branch_sha(root + "/alice/demo.git", "master")
    @async.with_task_group(group => {
      let (stdin, writer) = @process.write_to_process()
      defer writer.close()
      group.spawn_bg(() => {
        writer.write(
          ({ "port": port, "token": token, "sha": sha } : Json).stringify(),
        )
        writer.close()
      })
      let (code, stdout, stderr) = @process.collect_output(
        "node",
        ["scripts/release-gh-smoke.mjs"],
        stdin~,
      )
      assert_eq(code, 0, msg=stderr.text())
      assert_true(stdout.text().contains("\"publish\":true"))
    })
  })
}

///|
async test "release browser pages escape text enforce CSRF and stream authorized public assets" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let access = @releases.access(repo, Some(actor))
    let service = @releases.Service::new(pool, root)
    let release = service.create(
      access,
      "v4.0.0",
      @gitops.branch_sha(repo.git_dir(root), "master"),
      "Title <script>alert(1)</script>",
      "<img src=x onerror=alert(1)>",
    )
    let sent = Ref(false)
    let asset = service.upload(
      access,
      release.id,
      "quoted\"file.zip",
      "",
      "application/zip",
      () => {
        if sent.val {
          None
        } else {
          sent.val = true
          Some(b"download payload")
        }
      },
    )
    let client = @http.Client("http://127.0.0.1:" + port.to_string())
    defer client.close()
    let route = "/alice/demo/releases/" + release.id.to_string()
    let response = client.get(route, extra_headers={
      "Cookie": cookie.name + "=" + cookie.value,
    })
    assert_eq(response.code, 200)
    let html = client.read_all().text()
    assert_true(
      html.contains("&lt;script&gt;") &&
      !html.contains("<script>alert(1)</script>"),
    )
    let csrf = @web_testkit.extract_attr(
      html, "name=\"csrf_token\"", "value=\"",
    )
    let denied = client.post(route + "/publish", "csrf_token=wrong", extra_headers={
      "Cookie": cookie.name + "=" + cookie.value,
      "Content-Type": "application/x-www-form-urlencoded",
    })
    assert_eq(denied.code, 403)
    ignore(client.read_all())
    let published = client.post(route + "/publish", "csrf_token=" + csrf, extra_headers={
      "Cookie": cookie.name + "=" + cookie.value,
      "Content-Type": "application/x-www-form-urlencoded",
    })
    assert_eq(published.code, 303)
    ignore(client.read_all())
    pool.with_client(c => {
      ignore(c.execute("UPDATE repository SET visibility='public' WHERE id=1"))
    })
    let download = client.get(
      "/alice/demo/releases/assets/" + asset.id.to_string() + "/download",
    )
    assert_eq(download.code, 200)
    assert_eq(download.headers.get("x-content-type-options"), Some("nosniff"))
    assert_true(
      download.headers.get("content-disposition").unwrap().contains("%22"),
    )
    assert_eq(client.read_all().binary(), b"download payload")
    pool.with_client(c => {
      ignore(c.execute("UPDATE repository SET visibility='private' WHERE id=1"))
    })
    assert_eq(
      client.get(
        "/api/v3/repos/alice/demo/release-assets/" +
        asset.id.to_string() +
        "/download",
      ).code,
      404,
    )
    ignore(client.read_all())
  })
}

///|
async test "release job credential publishes only its repository and is revoked by cancellation" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let source =
      #|on: workflow_dispatch
      #|permissions: {contents: write, actions: read}
      #|jobs:
      #|  publish:
      #|    runs-on: [self-hosted, linux]
      #|    steps:
      #|      - run: echo publish
    let sha = @test_support.workflow_commit(repo.git_dir(root), source)
    let run = @pipeline.create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    let c = @pipeline.Coordinator::new(pool)
    let provider = "c".repeat(64)
    let attempt = "d".repeat(64)
    ignore(
      c.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "release-api",
        provider,
        ["self-hosted", "linux"],
        [repo],
      ),
    )
    let assignment = c
      .claim(provider, {
        version: 1,
        request_id: "a".repeat(32),
        attempt_token: attempt,
        runner_os: None,
      })
      .unwrap()
    let id = number(assignment.attempt_id)
    ignore(c.start(id, attempt, 1, execution_id="e".repeat(32)))
    let grant = c.api_runtime(id, attempt, {
      version: 1,
      execution_id: "e".repeat(32),
    })
    let body : Json = {
      "tag_name": "v5.0.0",
      "target_commitish": sha,
      "name": "Job release",
      "draft": true,
    }
    assert_eq(
      api_test_request(
        port,
        "/repos/alice/demo/releases",
        grant.token,
        Some(body),
      ).0,
      201,
    )
    assert_eq(
      api_test_request(
        port,
        "/repos/bob/demo/releases",
        grant.token,
        Some(body),
      ).0,
      403,
    )
    let (status, history) = api_test_request(
      port,
      "/repos/alice/demo/actions/workflows/build.yml/runs",
      grant.token,
      None,
    )
    assert_eq(status, 200)
    assert_true(history.stringify().contains(sha))
    c.cancel_run(actor, repo, run.number)
    assert_eq(
      api_test_request(
        port,
        "/repos/alice/demo/releases",
        grant.token,
        Some(body),
      ).0,
      401,
    )
  })
}
