///|
async test "MR workflow settings and execution approval require current authorized CSRF forms" {
  @web_testkit.with_repository_test_app((port, pool, root, alice, bob) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let owner = @identity.active_user_by_name(pool, "alice")
    let dir = repo.git_dir(root)
    let base = @test_support.workflow_commit(
      dir, @test_support.single_job_workflow,
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", base]))
    ignore(
      @test_support.merge_test_commit(
        dir,
        "feature",
        base,
        "HTTP checks\n",
        preserve_files=true,
      ),
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
        ),
      )
    })
    let scope = @repository.repository_scope(pool, owner, repo)
    let settings = "/alice/demo/settings/branches"
    let (_, page) = @web_testkit.http_get_path_with_cookie(
      port, settings, alice,
    )
    let csrf = @web_testkit.extract_attr(
      page, "name=\"csrf_token\"", "value=\"",
    )
    let fields = "branch=master&approvals=0&allow_self_approval=on&checks=.github%2Fworkflows%2Fbuild.yml"
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, settings, fields, alice).0.code,
      403,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        settings,
        "csrf_token=\{csrf}&\{fields}",
        alice,
      ).0.code,
      303,
    )
    assert_eq(@collaboration.required_merge_checks(pool, scope, "master"), [
      ".github/workflows/build.yml",
    ])
    let rules = @collaboration.branch_rules(pool, scope)
    assert_eq(rules.length(), 1)
    assert_true(rules[0].allow_self_approval)
    let (_, saved) = @web_testkit.http_get_path_with_cookie(
      port, settings, alice,
    )
    assert_true(saved.contains("Edit rule"))
    assert_true(saved.contains(".github/workflows/build.yml</textarea>"))
    let (_, create_page) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests/new", bob,
    )
    let member_csrf = @web_testkit.extract_attr(
      create_page, "name=\"csrf_token\"", "value=\"",
    )
    let (created, body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/merge-requests",
      "csrf_token=\{member_csrf}&title=Checks&source=feature&target=master",
      bob,
    )
    assert_eq(created.code, 303, msg=body)
    let detail = "/alice/demo/merge-requests/1"
    let (_, member_page) = @web_testkit.http_get_path_with_cookie(
      port, detail, bob,
    )
    assert_true(member_page.contains("Awaiting manager approval"))
    assert_false(member_page.contains(">Approve and run checks</button>"))
    assert_true(
      member_page.contains("<option value=\"approved\">Approve</option>"),
    )
    assert_false(member_page.contains("Request changes</option>"))
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        detail + "/approve-checks",
        "csrf_token=\{member_csrf}&version=1",
        bob,
      ).0.code,
      403,
    )
    let (_, manager_page) = @web_testkit.http_get_path_with_cookie(
      port, detail, alice,
    )
    let manager_csrf = @web_testkit.extract_attr(
      manager_page, "name=\"csrf_token\"", "value=\"",
    )
    assert_true(manager_page.contains("Approve and run checks"))
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        detail + "/approve-checks",
        "version=1",
        alice,
      ).0.code,
      403,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        detail + "/merge",
        "csrf_token=\{manager_csrf}&version=1",
        alice,
      ).0.code,
      400,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        detail + "/approve-checks",
        "csrf_token=\{manager_csrf}&version=1",
        alice,
      ).0.code,
      303,
    )
    assert_true(@pipeline.run_next_merge_check(pool, root))
    let (_, queued) = @web_testkit.http_get_path_with_cookie(
      port, detail, alice,
    )
    assert_true(queued.contains("Queued"))
    assert_true(queued.contains("/alice/demo/pipelines/1"))
    let (_, run_page) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/pipelines/1", alice,
    )
    assert_true(run_page.contains("Pull request !1, version 1"))
    assert_true(run_page.contains("/alice/demo/merge-requests/1?version=1"))
    ignore(
      @test_support.merge_test_commit(
        dir,
        "feature",
        @gitops.branch_sha(dir, "feature"),
        "new version\n",
        preserve_files=true,
      ),
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        detail + "/approve-checks",
        "csrf_token=\{manager_csrf}&version=1",
        alice,
      ).0.code,
      400,
    )
    let (_, historical) = @web_testkit.http_get_path_with_cookie(
      port,
      detail + "?version=1",
      alice,
    )
    assert_true(historical.contains("Viewing an older version"))
    assert_false(historical.contains(">Approve and run checks</button>"))
    assert_eq(
      @web_testkit.http_get_path_with_cookie(
        port, "/bob/demo/merge-requests/1", alice,
      ).0.code,
      404,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        settings,
        "csrf_token=\{csrf}&branch=master&approvals=0&checks=..%2Fsecret.yml",
        alice,
      ).0.code,
      400,
    )
    assert_eq(@collaboration.required_merge_checks(pool, scope, "master"), [
      ".github/workflows/build.yml",
    ])
  })
}

///|
async test "automatically discovered workflows appear as optional in the MR page" {
  @web_testkit.with_repository_test_app((port, pool, root, alice, _) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let actor = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, actor, repo)
    let dir = repo.git_dir(root)
    let base = @test_support.workflow_commit(
      dir,
      @test_support.single_job_workflow.replace_all(
        old="workflow_dispatch",
        new="pull_request",
      ),
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", base]))
    ignore(
      @test_support.merge_test_commit(
        dir,
        "feature",
        base,
        "optional CI\n",
        preserve_files=true,
      ),
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, dir, actor, "Automatic", "", "feature", "master", false,
    )
    assert_true(@pipeline.run_next_merge_check(pool, root))
    assert_false(@collaboration.merge_checks(pool, mr)[0].required)
    let (response, page) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests/1", alice,
    )
    assert_eq(response.code, 200)
    assert_true(page.contains("Automatic workflow · optional for merge"))
    assert_true(page.contains("/alice/demo/pipelines/1"))
  })
}
