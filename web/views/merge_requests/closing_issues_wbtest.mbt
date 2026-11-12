///|
async test "browser merge forms confirm closing directives with the displayed metadata version" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let number = @collaboration.create_issue(
      pool, scope, actor, "Browser closure", "", 0L,
    )
    let dir = repo.git_dir(root)
    ignore(
      @test_support.merge_test_commit(
        dir,
        "closing",
        @gitops.branch_sha(dir, "master"),
        "fix\n",
      ),
    )
    let mr = @collaboration.create_merge_request(
      pool,
      scope,
      dir,
      actor,
      "Fix",
      "Closes #\{number}",
      "closing",
      "master",
      false,
    )
    let base = "/alice/demo/merge-requests/\{mr.number}"
    let (_, html) = @web_testkit.http_get_path_with_cookie(port, base, cookie)
    let merge_start = html.find("action=\"\{base}/merge\"").unwrap()
    let merge_form = html[merge_start:].split_once("</form>").unwrap().0.to_owned()
    assert_true(merge_form.contains("name=\"edit_version\" value=\"1\""))
    let csrf = @web_testkit.extract_attr(
      html, "name=\"csrf_token\"", "value=\"",
    )
    @collaboration.edit_merge_request(
      pool,
      scope,
      actor,
      mr,
      "edit",
      mr.title,
      "Fixes #\{number}",
    )
    let (stale, _) = @web_testkit.http_post_path_with_cookie(
      port,
      base + "/merge",
      "csrf_token=\{csrf}&version=1&edit_version=1",
      cookie,
    )
    assert_eq(stale.code, 400)
    assert_eq(@collaboration.require_issue(pool, scope, number).status, "open")
    let (queued, _) = @web_testkit.http_post_path_with_cookie(
      port,
      base + "/merge",
      "csrf_token=\{csrf}&version=1&edit_version=2",
      cookie,
    )
    assert_eq(queued.code, 303)
    assert_true(@collaboration.run_next_merge_job(pool, root))
    assert_eq(
      @collaboration.require_issue(pool, scope, number).status,
      "closed",
    )
  })
}
