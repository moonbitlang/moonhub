///|
async test "users create repositories under their own name from the workspace" {
  @web_testkit.with_repository_test_app((port, pool, root, alice, bob) => {
    let (page, body) = @web_testkit.http_get_path_with_cookie(port, "/", alice)
    assert_eq(page.code, 200)
    assert_true(body.contains("href=\"/alice/-/repositories/new\""))
    assert_true(body.contains("New repository"))
    let (_, bob_body) = @web_testkit.http_get_path_with_cookie(port, "/", bob)
    assert_true(bob_body.contains("href=\"/bob/-/repositories/new\""))
    assert_true(!bob_body.contains("href=\"/alice/-/repositories/new\""))
    let csrf = @web_testkit.repository_test_token(port, "alice", alice)
    let (created, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/-/repositories",
      "csrf_token=\{csrf}&name=notes&visibility=private",
      alice,
    )
    assert_eq(created.code, 303)
    assert_true(@repository.run_next_repository_job(pool, root, None))
    let owner = @identity.active_user_by_name(pool, "alice")
    let personal = @identity.personal_namespace(pool, owner).unwrap_or_else(() => {
      fail("owner has no personal namespace")
    })
    assert_eq(
      @repository.require_repository_job(pool, personal, "notes").status,
      "succeeded",
    )
    assert_true(
      @repository.can_access_repository(
        pool,
        owner,
        { owner: "alice", name: "notes", },
        @repository.Write,
      ),
    )
    let (repo_page, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/notes", alice,
    )
    assert_eq(repo_page.code, 200)
    let (outsider, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/notes", bob,
    )
    assert_eq(outsider.code, 404)
  })
}
