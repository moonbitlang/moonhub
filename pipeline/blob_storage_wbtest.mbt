///|
async test "storage cutover preserves old artifacts and independent cache destinations" {
  with_protocol_fixture((original, pool, root, _, _, _) => {
    let one = @fs.tmpdir(prefix="moonhub-blob-one-")
    defer @fs.rmdir(one, recursive=true)
    let two = @fs.tmpdir(prefix="moonhub-blob-two-")
    defer @fs.rmdir(two, recursive=true)
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
    let cache = cache_test_save(
      c,
      root,
      grant.token,
      "independent-cache",
      b"cache",
    )
    let create = c.artifact_rpc(
      grant.token,
      "CreateArtifact",
      artifact_test_request(assignment, { "name": "cutover", "version": 4 }),
    )
    let (id, sig) = artifact_test_url(create, "signed_upload_url")
    c.stage_artifact_block(root, id, sig, "YQ==", b"original")
    c.commit_artifact_blocks(root, id, sig, ["YQ=="])
    let digest = "sha256:" +
      @crypto.bytes_to_hex_string(@crypto.sha256(b"original"))
    ignore(
      c.artifact_rpc(
        grant.token,
        "FinalizeArtifact",
        artifact_test_request(assignment, {
          "name": "cutover",
          "size": "8",
          "hash": digest,
        }),
      ),
    )
    let read = c.artifact_rpc(
      grant.token,
      "GetSignedArtifactURL",
      artifact_test_request(assignment, { "name": "cutover" }),
    )
    let (_, read_sig) = artifact_test_url(read, "signed_url")
    let changed = @storage.Config::parse({
      "artifacts": "two",
      "caches": "two",
      "backends": { "two": { "type": "fs", "root": two } },
    })
    let restarted = Coordinator::new(
      pool,
      storage=changed,
      clock=original.clock,
    )
    assert_eq(
      artifact_test_text(restarted.artifact_blob(root, id, read_sig)),
      "original",
    )
    let cached = restarted.cache_rpc(
      grant.token,
      "GetCacheEntryDownloadURL",
      cache_test_request("independent-cache"),
    )
    let (cache_id, cache_sig) = artifact_test_url(cached, "signed_download_url")
    assert_eq(cache_id, cache)
    assert_eq(
      artifact_test_text(restarted.artifact_blob(root, cache_id, cache_sig)),
      "cache",
    )
    assert_false(@fs.readdir(two).is_empty())
    assert_false(@fs.exists(root + "/.pipeline-artifacts"))
    assert_eq(
      pool.with_client(client => {
        (
          client
          .query_one("SELECT COUNT(*) AS n FROM pipeline_blob_garbage")
          .get_name("n") : Int64)
      }),
      0L,
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_artifact SET state='deleted' WHERE id=?",
          params=[id],
        ),
      )
    })
    restarted.cleanup_artifacts(root)
    assert_true(@fs.readdir(one).is_empty())
    assert_eq(
      pool.with_client(client => {
        (
          client
          .query_one("SELECT COUNT(*) AS n FROM pipeline_blob_garbage")
          .get_name("n") : Int64)
      }),
      0L,
    )
  })
}

///|
async test "cascade deletion retains storage cleanup intent and retries failed deletion" {
  with_protocol_fixture((c, pool, root, _, _, clock) => {
    let (a, grant) = artifact_test_start(c)
    let create = c.artifact_rpc(
      grant.token,
      "CreateArtifact",
      artifact_test_request(a, { "name": "cascade", "version": 4 }),
    )
    let (id, sig) = artifact_test_url(create, "signed_upload_url")
    c.stage_artifact_block(root, id, sig, "YQ==", b"partial")
    let key = pool.with_client(client => {
      (
        client
        .query_one("SELECT storage_key FROM pipeline_artifact WHERE id=?", params=[
          id,
        ])
        .get_name("storage_key") : String)
    })
    pool.with_client(client => {
      ignore(
        client.execute("DELETE FROM pipeline_run WHERE id=?", params=[
          @protocol.parse_decimal(a.run_id).unwrap(),
        ]),
      )
      assert_true(
        client.query_opt(
          "SELECT key FROM pipeline_blob_garbage WHERE key=? AND kind='namespace'",
          params=[key],
        )
        is Some(_),
      )
      ignore(
        client.execute("UPDATE pipeline_blob_garbage SET not_before_ms=?", params=[
          clock.val,
        ]),
      )
    })
    // A namespace temporarily inaccessible to cleanup must retain its intent.
    @fs.rename(root + "/.pipeline-artifacts", root + "/blobs-offline")
    @fs.symlink(target=root + "/blobs-offline", root + "/.pipeline-artifacts")
    try c.cleanup_artifacts(root) catch {
      _ => ()
    } noraise {
      _ => fail("cleanup followed a replaced storage root")
    }
    assert_true(
      pool.with_client(client => {
        client.query_opt("SELECT key FROM pipeline_blob_garbage WHERE key=?", params=[
          key,
        ])
        is Some(_)
      }),
    )
    @fs.remove(root + "/.pipeline-artifacts")
    @fs.rename(root + "/blobs-offline", root + "/.pipeline-artifacts")
    c.cleanup_artifacts(root)
    assert_false(@fs.exists(artifact_directory(root, key)))
    assert_true(
      pool.with_client(client => {
        client.query_all("SELECT * FROM pipeline_blob_garbage").is_empty()
      }),
    )
  })
}

///|
async test "S3 live artifacts and caches remain readable after switching defaults back to fs" {
  guard @env.get_env_var("MOONHUB_TEST_S3_CONFIG") is Some(value) else {
    return
  }
  with_protocol_fixture((original, pool, root, _, _, clock) => {
    let config = @storage.Config::parse(@json.parse(value))
    let c = Coordinator::new(pool, storage=config, clock=original.clock)
    let (a, grant) = artifact_test_start(c)
    let (id, sig) = artifact_test_url(
      c.artifact_rpc(
        grant.token,
        "CreateArtifact",
        artifact_test_request(a, { "name": "remote", "version": 4 }),
      ),
      "signed_upload_url",
    )
    c.stage_artifact_block(root, id, sig, "YQ==", b"remote-bytes")
    c.commit_artifact_blocks(root, id, sig, ["YQ=="])
    let hash = "sha256:" +
      @crypto.bytes_to_hex_string(@crypto.sha256(b"remote-bytes"))
    ignore(
      c.artifact_rpc(
        grant.token,
        "FinalizeArtifact",
        artifact_test_request(a, {
          "name": "remote",
          "size": "12",
          "hash": hash,
        }),
      ),
    )
    let (_, read_sig) = artifact_test_url(
      c.artifact_rpc(
        grant.token,
        "GetSignedArtifactURL",
        artifact_test_request(a, { "name": "remote" }),
      ),
      "signed_url",
    )
    let cache = cache_test_save(
      c,
      root,
      grant.token,
      "remote-cache",
      b"cached-bytes",
    )
    assert_eq(
      artifact_test_text(original.artifact_blob(root, id, read_sig)),
      "remote-bytes",
    )
    let (_, cache_sig) = artifact_test_url(
      original.cache_rpc(
        grant.token,
        "GetCacheEntryDownloadURL",
        cache_test_request("remote-cache"),
      ),
      "signed_download_url",
    )
    assert_eq(
      artifact_test_text(original.artifact_blob(root, cache, cache_sig)),
      "cached-bytes",
    )
    assert_false(@fs.exists(root + "/.pipeline-artifacts"))
    pool.with_client(client => {
      ignore(
        client.execute("DELETE FROM pipeline_run WHERE id=?", params=[
          @protocol.parse_decimal(a.run_id).unwrap(),
        ]),
      )
      ignore(
        client.execute("UPDATE pipeline_blob_garbage SET not_before_ms=?", params=[
          clock.val,
        ]),
      )
    })
    original.cleanup_artifacts(root)
    assert_true(
      pool.with_client(client => {
        client.query_all("SELECT * FROM pipeline_blob_garbage").is_empty()
      }),
    )
    assert_false(@fs.exists(root + "/.pipeline-artifacts"))
  })
}

///|
async test "one unavailable backend does not block reclaiming another backend" {
  with_protocol_fixture((c, pool, root, _, _, clock) => {
    @fs.mkdir(root + "/bad-root")
    @fs.mkdir(root + "/good-root")
    @fs.mkdir(root + "/outside")
    @fs.symlink(target=root + "/outside", root + "/bad-root/bad")
    @fs.mkdir(root + "/good-root/good")
    @fs.write_file(root + "/good-root/good/data", b"x")
    let bad = @storage.filesystem(root + "/bad-root").location()
    let good = @storage.filesystem(root + "/good-root").location()
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO pipeline_blob_garbage(location,key,kind,not_before_ms) VALUES(?,'bad','namespace',?)",
          params=[bad, clock.val - 1L],
        ),
      )
      ignore(
        client.execute(
          "INSERT INTO pipeline_blob_garbage(location,key,kind,not_before_ms) VALUES(?,'good','namespace',?)",
          params=[good, clock.val],
        ),
      )
    })
    try c.cleanup_artifacts(root) catch {
      _ => ()
    } noraise {
      _ => fail("failed backend was reported as clean")
    }
    assert_false(@fs.exists(root + "/good-root/good"))
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT count(*) AS n FROM pipeline_blob_garbage")
          .get_name("n") : Int64),
        1L,
      )
    })
    @fs.remove(root + "/bad-root/bad")
    c.cleanup_artifacts(root)
    assert_true(
      pool.with_client(client => {
        client.query_all("SELECT * FROM pipeline_blob_garbage").is_empty()
      }),
    )
  })
}
