///|
async test "repository access is consistent for private public admin and disabled users" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let admin = @identity.active_user_by_name(pool, "admin")
    let private_repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let public_repo : @domain.RepoId = { owner: "alice", name: "public", }
    assert_true(can_access_repository(pool, alice, private_repo, Read))
    assert_true(can_access_repository(pool, alice, private_repo, Write))
    assert_true(!can_access_repository(pool, bob, private_repo, Read))
    assert_true(!can_access_repository(pool, bob, private_repo, Write))
    assert_true(can_access_repository(pool, bob, public_repo, Read))
    assert_true(!can_access_repository(pool, bob, public_repo, Write))
    assert_true(can_access_repository(pool, admin, private_repo, Write))
    assert_true(
      !can_access_repository(
        pool,
        admin,
        { owner: "alice", name: "unknown", },
        Read,
      ),
    )
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
      )
    })
    assert_true(can_access_repository(pool, bob, private_repo, Write))
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'disabled' WHERE id = 2",
      )
    })
    assert_true(!can_access_repository(pool, bob, public_repo, Read))
    assert_true(!can_access_repository(pool, bob, private_repo, Write))
  })
}

///|
async test "repository paths reject symlink aliases into another namespace" {
  @test_support.with_git_test_repo((root, git_dir) => {
    assert_eq(
      resolve_repository_dir(root, { owner: "alice", name: "demo", }),
      @fs.realpath(git_dir),
    )
    @fs.mkdir("\{root}/bob")
    @fs.symlink(target=git_dir, "\{root}/bob/stolen.git")
    try resolve_repository_dir(root, { owner: "bob", name: "stolen", }) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted cross-namespace symlink")
    }
  })
}
