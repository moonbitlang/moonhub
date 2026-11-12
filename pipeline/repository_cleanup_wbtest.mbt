///|
async test "repository deletion cleans persisted artifact and cache destinations after restart and preserves late-upload recovery" {
  with_protocol_fixture((original, pool, root, _, _, clock) => {
    let one = root + "/artifact-store"
    let two = root + "/cache-store"
    let config = @storage.Config::parse({
      "artifacts": "one",
      "caches": "two",
      "backends": {
        "one": { "type": "fs", "root": one },
        "two": { "type": "fs", "root": two },
      },
    })
    let c = Coordinator::new(pool, storage=config, clock=original.clock)
    let (assignment, grant) = artifact_test_start(c)
    ignore(cache_test_save(c, root, grant.token, "deleted-cache", b"cache"))
    let (id, sig) = artifact_test_url(
      c.artifact_rpc(
        grant.token,
        "CreateArtifact",
        artifact_test_request(assignment, {
          "name": "deleted-artifact",
          "version": 4,
        }),
      ),
      "signed_upload_url",
    )
    c.stage_artifact_block(root, id, sig, "YQ==", b"partial")
    let (legacy_id, legacy_sig) = artifact_test_url(
      original.artifact_rpc(
        grant.token,
        "CreateArtifact",
        artifact_test_request(assignment, {
          "name": "deleted-legacy",
          "version": 4,
        }),
      ),
      "signed_upload_url",
    )
    original.stage_artifact_block(
      root, legacy_id, legacy_sig, "YQ==", b"legacy",
    )
    let key : String = pool.with_client(client => {
      let key = client
        .query_one("SELECT storage_key FROM pipeline_artifact WHERE id=?", params=[
          id,
        ])
        .get_name("storage_key")
      client.batch_execute(
        (
          #|UPDATE pipeline_job_attempt SET status='completed',conclusion='success',finished_at=datetime('now');
          #|UPDATE pipeline_job SET status='completed',conclusion='success';
          #|UPDATE pipeline_run SET status='completed',conclusion='success';
        ),
      )
      key
    })
    let actor = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, actor, protocol_repo)
    @repository.delete_repository(
      pool,
      root,
      actor,
      protocol_repo,
      scope.id,
      protocol_repo.path(),
    )
    @fs.rename(one, one + "-offline")
    @fs.symlink(target=one + "-offline", one)
    assert_true(
      @repository.run_next_repository_deletion(
        pool,
        root,
        cleanup_attachments=_ => (),
        cleanup_artifacts=keys => original.cleanup_repository_files(root, keys),
      ),
    )
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT attempts FROM repository_deletion")
          .get_name("attempts") : Int64),
        1L,
      )
      ignore(
        client.execute(
          "UPDATE repository_deletion SET next_attempt_at=datetime('now')",
        ),
      )
    })
    @fs.remove(one)
    @fs.rename(one + "-offline", one)
    assert_true(
      @repository.run_next_repository_deletion(
        pool,
        root,
        cleanup_attachments=_ => (),
        cleanup_artifacts=keys => original.cleanup_repository_files(root, keys),
      ),
    )
    assert_true(@fs.readdir(one).is_empty())
    assert_true(@fs.readdir(two).is_empty())
    assert_true(@fs.readdir(root + "/.pipeline-artifacts").is_empty())
    assert_false(@fs.exists(protocol_repo.git_dir(root)))
    pool.with_client(client => {
      assert_true(
        client.query_all("SELECT * FROM repository_deletion").is_empty(),
      )
      assert_eq(
        client
        .query_all("SELECT * FROM pipeline_blob_garbage WHERE kind='namespace'")
        .length(),
        3,
      )
    })
    // Model an already-issued upload finishing after the first deletion sweep.
    @storage.filesystem(one).put(key + "/late", b"late")
    pool.with_client(client => {
      ignore(
        client.execute("UPDATE pipeline_blob_garbage SET not_before_ms=?", params=[
          clock.val,
        ]),
      )
    })
    original.cleanup_artifacts(root)
    assert_true(@fs.readdir(one).is_empty())
    pool.with_client(client => {
      assert_true(
        client.query_all("SELECT * FROM pipeline_blob_garbage").is_empty(),
      )
    })
  })
}
