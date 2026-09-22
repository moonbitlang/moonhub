///|
async test "reference transaction ignores tags deletes and unauthorized auto execution" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let actor = @identity.active_user_by_name(pool, "alice")
    set_pipeline_push_enabled(pool, root, actor, repo, true)
    let sha = @gitops.branch_sha(repo.git_dir(root), "master")
    let zero = "0".repeat(40)
    for
      line in [
        "\{zero} \{sha} refs/tags/v1",
        "\{sha} \{zero} refs/heads/master",
        "\{sha} \{sha} refs/heads/master",
        "ref:refs/heads/master ref:refs/heads/main HEAD",
      ] {
      record_received_transaction(
        pool,
        actor,
        repo,
        "a".repeat(32),
        "prepared",
        line,
      )
    }
    assert_true(list_ref_events(pool, actor, repo).is_empty())
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
        ),
      )
    })
    let contributor = @identity.active_user_by_name(pool, "bob")
    record_received_transaction(
      pool,
      contributor,
      repo,
      "b".repeat(32),
      "prepared",
      "\{zero} \{sha} refs/heads/new",
    )
    assert_true(list_ref_events(pool, actor, repo).is_empty())
    try set_pipeline_push_enabled(pool, root, contributor, repo, false) catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("member changed automatic execution settings")
    }
  })
}

///|
async test "ambiguous prepared refs block new writes instead of inventing a successful push" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let actor = @identity.active_user_by_name(pool, "alice")
    set_pipeline_push_enabled(pool, root, actor, repo, true)
    let sha = @gitops.branch_sha(repo.git_dir(root), "master")
    record_received_transaction(
      pool,
      actor,
      repo,
      "a".repeat(32),
      "prepared",
      "\{"b".repeat(40)} \{"c".repeat(40)} refs/heads/master",
    )
    try
      with_repository_write(pool, root, actor, repo, (_, _) => {
        fail("entered write while recovery was ambiguous")
        ()
      })
    catch {
      @domain.BadRequest(message~) =>
        assert_true(message.contains("unconfirmed push event"))
      err => raise err
    } noraise {
      _ => fail("accepted ambiguous event")
    }
    assert_eq(@gitops.branch_sha(repo.git_dir(root), "master"), sha)
  })
}
