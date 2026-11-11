///|
async test "anonymous repository reads require public ready registration" {
  @test_support.with_ssh_test_db(pool => {
    let public_repo : @domain.RepoId = { owner: "alice", name: "public", }
    let private_repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    assert_true(can_read_repository(pool, None, public_repo))
    assert_true(!can_read_repository(pool, None, private_repo))
    assert_true(can_read_repository(pool, Some(alice), private_repo))
    assert_true(!can_read_repository(pool, Some(bob), private_repo))
    assert_true(can_read_repository(pool, Some(bob), public_repo))
    assert_true(!can_access_repository(pool, bob, public_repo, Write))
    assert_true(
      !can_read_repository(pool, None, { owner: "alice", name: "missing", }),
    )
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository SET ready = 0 WHERE name = 'public'",
      )
    })
    assert_true(!can_read_repository(pool, None, public_repo))
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository SET ready = 1, visibility = 'private' WHERE name = 'public'",
      )
    })
    assert_true(!can_read_repository(pool, None, public_repo))
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository SET visibility = 'public' WHERE name = 'public'",
      )
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'disabled' WHERE id = 2",
      )
    })
    assert_true(!can_read_repository(pool, Some(bob), public_repo))
  })
}
