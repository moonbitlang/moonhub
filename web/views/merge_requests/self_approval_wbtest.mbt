///|
async test "branch self approval forms enforce CSRF, manager permission and current policy" {
  @web_testkit.with_repository_test_app((port, pool, root, alice, bob) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let owner = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, owner, repo)
    let dir = repo.git_dir(root)
    ignore(
      @test_support.merge_test_commit(
        dir,
        "self",
        @gitops.branch_sha(dir, "master"),
        "source",
      ),
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
        ),
      )
    })
    let settings = "/alice/demo/settings/branches"
    let (_, page) = @web_testkit.http_get_path_with_cookie(
      port, settings, alice,
    )
    assert_true(page.contains("name=\"allow_self_approval\">"))
    let csrf = @web_testkit.extract_attr(
      page, "name=\"csrf_token\"", "value=\"",
    )
    let fields = "branch=master&approvals=1&allow_self_approval=on"
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, settings, fields, alice).0.code,
      403,
    )
    assert_true(@collaboration.branch_rules(pool, scope).is_empty())
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        settings,
        "csrf_token=\{csrf}&\{fields}",
        alice,
      ).0.code,
      303,
    )
    let (_, saved) = @web_testkit.http_get_path_with_cookie(
      port, settings, alice,
    )
    assert_true(saved.contains("Author approval allowed"))
    assert_true(saved.contains("name=\"allow_self_approval\" checked"))
    assert_eq(
      @web_testkit.http_get_path_with_cookie(port, settings, bob).0.code,
      403,
    )
    let (_, create) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests/new", bob,
    )
    let token = @web_testkit.extract_attr(
      create, "name=\"csrf_token\"", "value=\"",
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        settings,
        "csrf_token=\{token}&branch=master&approvals=0",
        bob,
      ).0.code,
      403,
    )
    assert_true(@collaboration.branch_rules(pool, scope)[0].allow_self_approval)
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        "/alice/demo/merge-requests",
        "csrf_token=\{token}&title=Self&source=self&target=master",
        bob,
      ).0.code,
      303,
    )
    let detail = "/alice/demo/merge-requests/1"
    let (_, enabled) = @web_testkit.http_get_path_with_cookie(port, detail, bob)
    assert_true(enabled.contains("<option value=\"approved\">Approve</option>"))
    assert_false(enabled.contains("cannot approve it yourself"))
    assert_false(enabled.contains("Request changes</option>"))
    assert_false(enabled.contains("Withdraw review</option>"))
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        detail + "/review",
        "csrf_token=\{token}&version=1&decision=approved",
        bob,
      ).0.code,
      303,
    )
    let (_, approved) = @web_testkit.http_get_path_with_cookie(
      port, detail, bob,
    )
    assert_true(approved.contains("1 approvals · 1 required"))
    assert_true(approved.contains("No conflicts. Ready to merge."))
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        detail + "/merge",
        "csrf_token=\{token}&version=1",
        bob,
      ).0.code,
      403,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        settings,
        "csrf_token=\{csrf}&branch=master&approvals=1",
        alice,
      ).0.code,
      303,
    )
    let (_, disabled) = @web_testkit.http_get_path_with_cookie(
      port, detail, bob,
    )
    assert_true(disabled.contains("cannot approve it yourself"))
    assert_false(
      disabled.contains("<option value=\"approved\">Approve</option>"),
    )
    assert_true(disabled.contains("0 approvals · 1 required"))
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        detail + "/review",
        "csrf_token=\{token}&version=1&decision=approved",
        bob,
      ).0.code,
      403,
    )
  })
}
