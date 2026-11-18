///|
async test "repository home shows each workflow's latest run on the default branch HEAD" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, outsider) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let actor = @identity.active_user_by_name(pool, "alice")
    let dir = repo.git_dir(root)
    let branch = "release/stable"
    let path = ".github/workflows/build.yml"
    let sha = @test_support.workflow_commit(
      dir,
      @test_support.single_job_workflow.replace_all(
        old="Protocol fixture",
        new="Build and test",
      ),
    )
    ignore(@gitops.run_git(dir, ["update-ref", "refs/heads/\{branch}", sha]))
    ignore(
      @gitops.run_git(dir, ["symbolic-ref", "HEAD", "refs/heads/\{branch}"]),
    )
    let first = @pipeline.create_run(pool, root, actor, repo, branch, path)
    let latest = @pipeline.create_run(pool, root, actor, repo, branch, path)
    let other = @pipeline.create_run(pool, root, actor, repo, "pipeline", path)
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE pipeline_run SET status='completed', conclusion='failure' WHERE id=?",
        params=[first.id],
      )
      let _ = client.execute(
        "UPDATE pipeline_run SET status='completed', conclusion='success' WHERE id=?",
        params=[latest.id],
      )
      ignore(
        client.execute(
          (
            #|INSERT INTO pipeline_run (repository_id, number, requested_by_user_id, workflow_path, workflow_name, source_branch, commit_sha, source_ref, definition_version, workflow_source, definition_json)
            #|SELECT repository_id, ?, requested_by_user_id, '.github/workflows/lint.yml', 'Lint <nightly>', source_branch, commit_sha, source_ref || '-lint', definition_version, workflow_source, definition_json
            #|FROM pipeline_run WHERE id=?
          ),
          params=[other.number + 1L, latest.id],
        ),
      )
    })
    let href = "/alice/demo/pipelines/\{latest.number}"
    for
      route in [
        "/alice/demo",
        "/alice/demo?rev=release%2Fstable",
        "/alice/demo/tree",
        "/alice/demo/tree/release/stable",
        "/alice/demo/tree/" + sha,
      ] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port, route, cookie,
      )
      assert_eq(response.code, 200, msg=route + body)
      assert_true(body.contains("Actions · In progress · 1 of 2 passed"))
      assert_true(body.contains("Build and test</span>"))
      assert_true(
        body.contains("Lint &lt;nightly&gt;</span><span class=\"muted\">Queued"),
      )
      assert_true(body.contains("href=\"\{href}\""))
      assert_true(
        !body.contains("href=\"/alice/demo/pipelines/\{first.number}\""),
      )
      assert_true(
        !body.contains("href=\"/alice/demo/pipelines/\{other.number}\""),
      )
    }
    let (detail, detail_body) = @web_testkit.http_get_path_with_cookie(
      port, href, cookie,
    )
    assert_eq(detail.code, 200)
    assert_true(detail_body.contains("<h1>Build and test</h1>"))
    for
      route in [
        "/alice/demo?rev=pipeline", "/alice/demo/tree/release/stable/.github",
      ] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port, route, cookie,
      )
      assert_eq(response.code, 200, msg=route + body)
      assert_true(!body.contains("class=\"commit-actions\""), msg=route)
    }
    let (denied, denied_body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", outsider,
    )
    assert_eq(denied.code, 404)
    assert_true(!denied_body.contains("class=\"commit-actions\""))
    // The default view still follows HEAD when a same-named tag points elsewhere.
    ignore(
      @gitops.run_git(dir, ["update-ref", "refs/tags/\{branch}", "master"]),
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE repository SET visibility='public' WHERE name='demo'",
        ),
      )
    })
    let (public_home, public_body) = @web_testkit.http_get_path(
      port, "/alice/demo",
    )
    assert_eq(public_home.code, 200)
    assert_true(!public_body.contains("class=\"commit-actions\""))
    let (signed_in, signed_in_body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", outsider,
    )
    assert_eq(signed_in.code, 200)
    assert_true(
      signed_in_body.contains("Actions · In progress · 1 of 2 passed"),
    )
    ignore(
      @gitops.run_git(dir, ["update-ref", "refs/heads/\{branch}", "master"]),
    )
    let (moved, moved_body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(moved.code, 200)
    assert_true(!moved_body.contains("class=\"commit-actions\""))
  })
}
