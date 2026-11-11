///|
async test "MR API exposes closing declarations through create read edit list and merge" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let token = @identity.create_access_token(
      pool, actor, "issue-closures", "merge", 1,
    )
    let scope = @repository.repository_scope(pool, actor, {
      owner: "alice",
      name: "demo",
    })
    let first = @collaboration.create_issue(pool, scope, actor, "First", "", 0L)
    let second = @collaboration.create_issue(
      pool, scope, actor, "Second", "", 0L,
    )
    let dir = "\{root}/alice/demo.git"
    ignore(
      @test_support.merge_test_commit(
        dir,
        "closing",
        @gitops.branch_sha(dir, "master"),
        "fix\n",
      ),
    )
    let (status, mr) = api_test_request(
      port,
      "/repos/alice/demo/mrs",
      token,
      Some({
        "title": "Closes #999",
        "description": "Closes #\{first}",
        "source": "closing",
        "target": "master",
      }),
    )
    assert_eq(status, 200)
    assert_true(mr is { "closing_issue_numbers": [String("1")], .. })
    let (_, data) = api_test_request(
      port,
      "/repos/alice/demo/mrs/1",
      token,
      None,
    )
    assert_true(
      data is { "mr": { "closing_issue_numbers": [String("1")], .. }, .. },
    )
    let (_, data) = api_test_request(port, "/repos/alice/demo/mrs", token, None)
    assert_true(
      data is { "items": [{ "closing_issue_numbers": [String("1")], .. }], .. },
    )
    let (status, data) = api_test_request(
      port,
      "/repos/alice/demo/mrs/1/edit",
      token,
      Some({
        "edit_version": "1",
        "description": "Fixes #\{second}, #\{second}. `Closes #\{first}`",
      }),
    )
    assert_eq(status, 200)
    assert_true(data is { "closing_issue_numbers": [String("2")], .. })
    for
      body in (
        [{ "version": "1" }, { "version": "1", "edit_version": "1" }] :
        Array[Json]) {
      let (status, _) = api_test_request(
        port,
        "/repos/alice/demo/mrs/1/merge",
        token,
        Some(body),
      )
      assert_eq(status, 400)
    }
    let (status, data) = api_test_request(
      port,
      "/repos/alice/demo/mrs/1/merge",
      token,
      Some({ "version": "1", "edit_version": "2" }),
    )
    assert_eq(status, 200)
    assert_true(
      data
      is {
        "closing_issue_numbers": [String("2")],
        "status": String("open"),
        ..
      },
    )
    assert_eq(@collaboration.require_issue(pool, scope, second).status, "open")
    assert_true(@collaboration.run_next_merge_job(pool, root))
    let (_, data) = api_test_request(
      port,
      "/repos/alice/demo/mrs/1",
      token,
      None,
    )
    assert_true(
      data
      is {
        "mr": {
          "closing_issue_numbers": [String("2")],
          "status": String("merged"),
          ..
        },
        ..
      },
    )
    assert_eq(@collaboration.require_issue(pool, scope, first).status, "open")
    assert_eq(
      @collaboration.require_issue(pool, scope, second).status,
      "closed",
    )
  })
}
