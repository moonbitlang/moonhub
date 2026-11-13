///|
async test "repository home summarizes only stable releases using the service latest policy" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, outsider) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let actor = @identity.active_user_by_name(pool, "alice")
    let access = @releases.access(repo, Some(actor))
    let service = @releases.Service::new(pool, root)
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(response.code, 200)
    assert_true(body.contains("No stable releases published."))
    assert_true(body.contains("View all releases"))
    let draft = service.create(
      access,
      "draft",
      "master",
      "Private draft",
      "",
      draft=true,
    )
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(response.code, 200)
    assert_true(body.contains("No stable releases published."))
    assert_true(!body.contains("Private draft"))
    let _ = service.create(
      access,
      "preview",
      "master",
      "Preview only",
      "",
      draft=false,
      prerelease=true,
    )
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(response.code, 200)
    assert_true(body.contains("No stable releases published."))
    assert_true(!body.contains("Private draft"))
    assert_true(!body.contains("Preview only"))
    let stable = service.create(
      access,
      "v1.0.0",
      "master",
      "Stable <one>",
      "",
      draft=false,
      latest=true,
    )
    let _ = service.create(
      access,
      "v2.0.0",
      "master",
      "Unpinned stable",
      "",
      draft=false,
      latest=false,
    )
    let sha = @gitops.branch_sha(repo.git_dir(root), "master")
    ignore(
      @gitops.run_git(repo.git_dir(root), [
        "update-ref", "refs/heads/feature/home", sha,
      ]),
    )
    for
      route in [
        "/alice/demo",
        "/alice/demo?rev=feature%2Fhome",
        "/alice/demo/tree",
        "/alice/demo/tree/feature/home",
        "/alice/demo/tree/" + sha,
      ] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port, route, cookie,
      )
      assert_eq(response.code, 200, msg=route + body)
      assert_true(body.contains("class=\"repository-releases\""))
      assert_true(body.contains("Stable &lt;one&gt;"))
      assert_true(body.contains("v1.0.0"))
      assert_true(body.contains("Latest</span>"))
      assert_true(body.contains("href=\"/alice/demo/releases/\{stable.id}\""))
      assert_true(body.contains(stable.published_at.unwrap()))
      assert_true(!body.contains("Unpinned stable"))
      assert_true(!body.contains("Private draft"))
    }
    for
      route in [
        "/alice/demo/tree/master/src",
        "/alice/demo/blob/master/src/main.mbt",
        "/alice/demo/commits",
        "/alice/demo/commit/" + sha,
        "/alice/demo/releases",
        "/alice/demo/releases/\{draft.id}",
      ] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port, route, cookie,
      )
      assert_eq(response.code, 200, msg=route + body)
      assert_true(!body.contains("class=\"repository-releases\""), msg=route)
    }
    for cookie in [None, Some(outsider)] {
      let (response, body) = match cookie {
        Some(cookie) =>
          @web_testkit.http_get_path_with_cookie(port, "/alice/demo", cookie)
        None => @web_testkit.http_get_path(port, "/alice/demo")
      }
      assert_eq(response.code, 404)
      assert_true(!body.contains("Stable &lt;one&gt;"))
    }
    pool.with_client(c => {
      ignore(
        c.execute("UPDATE repository SET visibility='public' WHERE name='demo'"),
      )
    })
    let (response, body) = @web_testkit.http_get_path(port, "/alice/demo")
    assert_eq(response.code, 200)
    assert_true(body.contains("Stable &lt;one&gt;"))
    assert_true(!body.contains("Private draft"))
    pool.with_client(c => {
      ignore(
        c.execute(
          "UPDATE repository SET visibility='private' WHERE name='demo'",
        ),
      )
      ignore(
        c.execute(
          "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
        ),
      )
    })
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", outsider,
    )
    assert_eq(response.code, 200)
    assert_true(body.contains("Stable &lt;one&gt;"))
    assert_true(!body.contains("Private draft"))
    assert_true(!body.contains("/settings/branches"))
  })
}

///|
async test "directory commit summary separates detail links from revision history and handles empty repositories" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let dir = root + "/alice/demo.git"
    let sha = @gitops.branch_sha(dir, "master")
    ignore(
      @gitops.run_git(dir, ["update-ref", "refs/heads/feature/history", sha]),
    )
    ignore(
      @gitops.run_git(dir, ["update-ref", "refs/tags/feature/history", sha]),
    )
    for rev in ["master", "feature/history", sha] {
      for suffix in ["?rev=", "/tree/"] {
        let (response, body) = @web_testkit.http_get_path_with_cookie(
          port,
          "/alice/demo" + suffix + @web_context.url_escape_path(rev),
          cookie,
        )
        assert_eq(response.code, 200, msg=body)
        let summary = body.split("class=\"commit-summary\">").collect()[1]
          .split("</div>")
          .collect()[0]
        assert_eq(
          summary.split("href=\"/alice/demo/commit/" + sha + "\"").count(),
          3,
        )
        assert_true(
          summary.contains(
            "href=\"/alice/demo/commits?rev=" +
            @web_context.url_escape_path(rev) +
            "\"",
          ),
        )
        assert_true(summary.contains("data-icon=\"history\""))
        assert_true(summary.contains(">Commits</a>"))
        assert_true(!body.contains(">History</a>"))
      }
    }
    let (_, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/blob/master/README.md", cookie,
    )
    assert_true(body.contains(">History</a>"))
    assert_true(body.contains("aria-label=\"Directory navigation\""))
    @repository.create_managed_repository(
      pool,
      root,
      { owner: "alice", name: "empty", },
      "private",
      false,
    )
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/empty", cookie,
    )
    assert_eq(response.code, 200, msg=body)
    assert_true(body.contains("No commits yet."))
    assert_true(body.contains("class=\"commit-history\""))
    assert_true(!body.contains("href=\"/alice/empty/commit/"))
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/empty/commits", cookie,
    )
    assert_eq(response.code, 200)
    assert_true(body.contains("No commits."))
  })
}
