///|
async test "retarget form enforces CSRF preserves errors and shows each revision target" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let dir = repo.git_dir(root)
    ignore(
      @gitops.merge_git(dir, [
        "update-ref",
        "refs/heads/release",
        @gitops.branch_sha(dir, "master"),
      ]),
    )
    ignore(
      @test_support.merge_test_commit(
        dir,
        "feature",
        @gitops.branch_sha(dir, "master"),
        "source\n",
      ),
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, dir, actor, "Retarget", "", "feature", "master", false,
    )
    let path = "/alice/demo/merge-requests/" + mr.number.to_string()
    let (_, html) = @web_testkit.http_get_path_with_cookie(port, path, cookie)
    assert_true(html.contains("Change target branch"))
    assert_true(html.contains("aria-describedby=\"mr-target-notice\""))
    let token = @web_testkit.extract_attr(
      html, "name=\"csrf_token\"", "value=\"",
    )
    let (denied, _) = @web_testkit.http_post_path_with_cookie(
      port,
      path + "/retarget",
      "target=release&edit_version=1",
      cookie,
    )
    assert_eq(denied.code, 403)
    let (invalid, error) = @web_testkit.http_post_path_with_cookie(
      port,
      path + "/retarget",
      "csrf_token=\{token}&target=missing&edit_version=1",
      cookie,
    )
    assert_eq(invalid.code, 400)
    assert_true(error.contains("role=\"alert\""))
    assert_true(error.contains("value=\"missing\" selected"))
    assert_eq(
      @collaboration.require_merge_request(pool, scope, mr.number).version,
      1L,
    )
    let (saved, _) = @web_testkit.http_post_path_with_cookie(
      port,
      path + "/retarget",
      "csrf_token=\{token}&target=release&edit_version=1",
      cookie,
    )
    assert_eq(saved.code, 303)
    let (_, latest) = @web_testkit.http_get_path_with_cookie(port, path, cookie)
    assert_true(latest.contains("into <code>release</code>"))
    assert_true(latest.contains("Changed target branch from"))
    let (_, old) = @web_testkit.http_get_path_with_cookie(
      port,
      path + "?version=1",
      cookie,
    )
    assert_true(old.contains("into <code>master</code>"))
    assert_false(old.contains("action=\"\{path}/retarget\""))
  })
}
