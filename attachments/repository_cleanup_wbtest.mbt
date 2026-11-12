///|
async test "stale attachment uploads cannot write to a same-name replacement" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    @repository.delete_repository(
      pool,
      root,
      actor,
      repo,
      scope.id,
      repo.path(),
    )
    assert_true(
      @repository.run_next_repository_deletion(
        pool,
        root,
        cleanup_attachments=ids => cleanup_repository_files(root, ids),
        cleanup_artifacts=_ => (),
      ),
    )
    @repository.create_managed_repository(pool, root, repo, "private", false)
    try upload(pool, root, scope, actor, "stale.txt", b"old request") catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale attachment uploaded to successor")
    }
    pool.with_client(client => {
      assert_true(client.query_all("SELECT * FROM attachment").is_empty())
    })
  })
}
