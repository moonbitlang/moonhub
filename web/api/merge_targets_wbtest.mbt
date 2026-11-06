///|
async test "MR edit API retargets atomically and returns historical target context" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let write = @identity.create_access_token(
      pool, actor, "retarget", "write", 1,
    )
    let read = @identity.create_access_token(pool, actor, "read", "read", 1)
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
      pool, scope, dir, actor, "Original", "Keep description", "feature", "master",
      false,
    )
    let path = "/repos/alice/demo/mrs/" + mr.number.to_string()
    let (denied, _) = api_test_request(
      port,
      path + "/edit",
      read,
      Some({ "target": "release", "edit_version": "1" }),
    )
    assert_eq(denied, 403)
    let (invalid, _) = api_test_request(
      port,
      path + "/edit",
      write,
      Some({
        "target": "missing",
        "title": "Must roll back",
        "edit_version": "1",
      }),
    )
    assert_eq(invalid, 400)
    assert_eq(
      @collaboration.require_merge_request(pool, scope, mr.number).title,
      "Original",
    )
    let (status, result) = api_test_request(
      port,
      path + "/edit",
      write,
      Some({ "target": "release", "edit_version": "1" }),
    )
    assert_eq(status, 200)
    assert_true(
      result
      is {
        "target": String("release"),
        "title": String("Original"),
        "description": String("Keep description"),
        "version": String("2"),
        "edit_version": String("2"),
        ..
      },
    )
    let (stale, _) = api_test_request(
      port,
      path + "/edit",
      write,
      Some({ "target": "master", "edit_version": "1" }),
    )
    assert_eq(stale, 400)
    let (_, historic) = api_test_request(
      port,
      path + "/diff?version=1",
      read,
      None,
    )
    assert_true(
      historic is { "target": String("master"), "version": String("1"), .. },
    )
    let (_, current) = api_test_request(
      port,
      path + "/diff?version=2",
      read,
      None,
    )
    assert_true(
      current is { "target": String("release"), "version": String("2"), .. },
    )
    let (noop, result) = api_test_request(
      port,
      path + "/edit",
      write,
      Some({ "target": "release", "edit_version": "2" }),
    )
    assert_eq(noop, 200)
    assert_true(
      result is { "edit_version": String("2"), "version": String("2"), .. },
    )
  })
}
