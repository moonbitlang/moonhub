///|
async test "S3 release assets survive backend changes CI cleanup and repository cascade" {
  guard @env.get_env_var("MOONHUB_TEST_S3_CONFIG") is Some(config_text) else {
    return
  }
  let config = @storage.Config::parse(@json.parse(config_text))
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let access = access(repo, Some(actor))
    let now = Ref(2000000000000L)
    let remote = Service::new(pool, root, storage=config, clock=() => now.val)
    let sha = @gitops.branch_sha(repo.git_dir(root), "master")
    let r = remote.create(access, "v3.0.0", sha, "S3 release", "")
    let chunks = Ref(0)
    let a = remote.upload(access, r.id, "app.zip", "", "application/zip", () => {
      if chunks.val == 9 {
        None
      } else {
        chunks.val += 1
        Some(Bytes::make(1048576, b'S'))
      }
    })
    assert_eq(a.size, 9437184L)
    assert_true(a.location.contains("\"type\":\"s3\""))
    ignore(remote.publish(access, r.id))
    // Saved descriptors remain readable with filesystem defaults after rollback.
    let fallback_service = Service::new(pool, root, clock=() => now.val)
    let bytes = Ref(0L)
    fallback_service.download(access, a.id, (_, reader, check) => {
      while reader.read() is Some(chunk) {
        check()
        bytes.val += chunk.length().to_int64()
      }
    })
    assert_eq(bytes.val, a.size)
    now.val += 864000000L
    remote.cleanup()
    assert_eq(remote.get(access, r.id).assets.length(), 1)
    pool.with_client(c => {
      ignore(
        c.execute("DELETE FROM repository_release WHERE id=?", params=[r.id]),
      )
    })
    assert_eq(
      pool.with_client(c => {
        (
          c
          .query_one("SELECT count(*) n FROM release_blob_garbage")
          .get_name("n") : Int64)
      }),
      1L,
    )
    remote.cleanup()
    now.val += 600001L
    remote.cleanup()
    assert_true(
      pool.with_client(c => {
        c.query_all("SELECT * FROM release_blob_garbage").is_empty()
      }),
    )
  })
}
