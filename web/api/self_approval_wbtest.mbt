///|
async test "MR API self approval shares branch policy without granting execution or merge scopes" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let read = @identity.create_access_token(pool, alice, "read", "read", 1)
    let write = @identity.create_access_token(pool, alice, "write", "write", 1)
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, alice, repo)
    let dir = repo.git_dir(root)
    ignore(
      @test_support.merge_test_commit(
        dir,
        "self",
        @gitops.branch_sha(dir, "master"),
        "source",
      ),
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, dir, alice, "API self approval", "", "self", "master", false,
    )
    let review = "/repos/alice/demo/mrs/1/review"
    let body : Json = { "version": "1", "decision": "approved" }
    assert_eq(api_test_request(port, review, write, Some(body)).0, 403)
    @collaboration.save_branch_rule(
      pool,
      scope,
      dir,
      alice,
      "master",
      true,
      1L,
      allow_self_approval=true,
    )
    assert_eq(api_test_request(port, review, read, Some(body)).0, 403)
    assert_eq(api_test_request(port, review, write, Some(body)).0, 200)
    assert_eq(@collaboration.merge_review_counts(pool, scope, mr).0, 1L)
    assert_eq(
      api_test_request(
        port,
        review,
        write,
        Some({ "version": "2", "decision": "approved" }),
      ).0,
      400,
    )
    for decision in ["changes_requested", "withdrawn"] {
      assert_eq(
        api_test_request(
          port,
          review,
          write,
          Some({ "version": "1", "decision": decision }),
        ).0,
        403,
      )
    }
    for action in ["approve-checks", "merge"] {
      assert_eq(
        api_test_request(
          port,
          "/repos/alice/demo/mrs/1/" + action,
          write,
          Some({ "version": "1" }),
        ).0,
        403,
      )
    }
    @collaboration.save_branch_rule(pool, scope, dir, alice, "master", true, 1L)
    assert_eq(api_test_request(port, review, write, Some(body)).0, 403)
    assert_eq(@collaboration.merge_review_counts(pool, scope, mr).0, 0L)
  })
}
