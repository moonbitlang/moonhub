///|
async test "published release tags reject managed writer mutation and preserve no-op pushes" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let sha = @gitops.branch_sha(repo.git_dir(root), "master")
    pool.with_client(c => {
      ignore(
        c.execute(
          "INSERT INTO repository_release(repository_id,tag,commit_sha,source_ref,title,draft,author_id) VALUES(1,'v1',?,'refs/moonhub/releases/test','Version',0,?)",
          params=[sha, actor.id],
        ),
      )
    })
    for next in ["0".repeat(40), "a".repeat(40)] {
      try
        record_received_transaction(
          pool,
          actor,
          repo,
          "1".repeat(32),
          "prepared",
          sha + " " + next + " refs/tags/v1\n",
        )
      catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("published tag mutation accepted")
      }
    }
    record_received_transaction(
      pool,
      actor,
      repo,
      "2".repeat(32),
      "prepared",
      sha + " " + sha + " refs/tags/v1\n",
    )
    record_received_transaction(
      pool,
      actor,
      repo,
      "3".repeat(32),
      "prepared",
      "0".repeat(40) + " " + sha + " refs/tags/v2\n",
    )
  })
}
