///|
async test "pending webhook deliveries pause during repository transfer and resume after rollback" {
  @test_support.with_ssh_test_db(pool => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let hook = save_hook(
      pool,
      actor,
      repo,
      0L,
      0L,
      "https://example.com/hook",
      "0123456789abcdef",
      ["push"],
      true,
      Policy::new(),
    )
    ping(pool, actor, repo, hook)
    pool.with_client(client => {
      client.batch_execute(
        "INSERT INTO repository_transfer(repository_id,target_team_id,name) VALUES(1,3,'demo'); UPDATE repository SET ready=0 WHERE id=1;",
      )
    })
    assert_true(claim(pool) is None)
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT status FROM webhook_delivery")
          .get_name("status") : String),
        "pending",
      )
      client.batch_execute(
        "UPDATE repository SET ready=1 WHERE id=1; DELETE FROM repository_transfer WHERE repository_id=1;",
      )
    })
    assert_true(claim(pool) is Some(_))
  })
}
