///|
async test "MR diff API exposes full and per-commit comparison identities with repository scope" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let git_dir = "\{root}/alice/demo.git"
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let read = @identity.create_access_token(pool, alice, "diff", "read", 1)
    let outside = @identity.create_access_token(pool, bob, "diff", "read", 1)
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let base = @gitops.branch_sha(git_dir, "master")
    let first = @test_support.merge_test_commit(
      git_dir, "feature", base, "one\n",
    )
    let second = @test_support.merge_test_commit(
      git_dir, "feature", first, "two\n",
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, git_dir, alice, "Diff API", "", "feature", "master", false,
    )
    let url = "/repos/alice/demo/mrs/1/diff?version=1"
    let (status, all) = api_test_request(port, url, read, None)
    assert_eq(status, 200)
    assert_true(
      all
      is {
        "comparison": String("all"),
        "commit_sha": Null,
        "base_sha": String(value),
        ..
      } &&
      value == base,
    )
    let (status, selected) = api_test_request(
      port,
      url + "&commit=" + second,
      read,
      None,
    )
    assert_eq(status, 200)
    assert_true(
      selected
      is {
        "comparison": String("commit"),
        "base_sha": String(value),
        "head_sha": String(head),
        "parent_count": Number(1, ..),
        ..
      } &&
      value == first &&
      head == second,
    )
    assert_true(
      selected is { "patch": String(patch), .. } && patch.contains("-one\n+two"),
    )
    for commit in [base, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] {
      let (status, _) = api_test_request(
        port,
        url + "&commit=" + commit,
        read,
        None,
      )
      assert_eq(status, 404)
    }
    let (status, _) = api_test_request(port, url + "&commit=HEAD", read, None)
    assert_eq(status, 400)
    let (status, _) = api_test_request(
      port,
      url + "&commit=" + second,
      outside,
      None,
    )
    assert_eq(status, 404)
    let third = @test_support.merge_test_commit(
      git_dir, "feature", second, "three\n",
    )
    ignore(@collaboration.refresh_merge_request(pool, scope, git_dir, mr))
    let (status, _) = api_test_request(
      port,
      url + "&commit=" + third,
      read,
      None,
    )
    assert_eq(status, 404)
    let (status, selected) = api_test_request(
      port,
      url + "&commit=" + first,
      read,
      None,
    )
    assert_eq(status, 200)
    assert_true(selected is { "head_sha": String(value), .. } && value == first)
  })
}
