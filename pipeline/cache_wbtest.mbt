///|
fn cache_test_request(key : String, version~ : String = "v1") -> Json {
  { "key": key, "version": version }
}

///|
async fn cache_test_save(
  c : Coordinator,
  root : String,
  token : String,
  key : String,
  bytes : Bytes,
  version~ : String = "v1",
) -> Int64 {
  let result = c.cache_rpc(
    token,
    "CreateCacheEntry",
    cache_test_request(key, version~),
  )
  let (id, sig) = artifact_test_url(result, "signed_upload_url")
  c.stage_artifact_block(root, id, sig, "YQ==", bytes)
  c.commit_artifact_blocks(root, id, sig, ["YQ=="])
  // The SDK can retry a completed single-PUT after its response was lost.
  c.stage_artifact_block(root, id, sig, "YQ==", bytes)
  c.commit_artifact_blocks(root, id, sig, ["YQ=="])
  let finalized : Json = {
    "key": key,
    "version": version,
    "size_bytes": bytes.length().to_string(),
  }
  assert_eq(c.cache_rpc(token, "FinalizeCacheEntryUpload", finalized), {
    "ok": true,
    "entry_id": id.to_string(),
  })
  assert_eq(c.cache_rpc(token, "FinalizeCacheEntryUpload", finalized), {
    "ok": true,
    "entry_id": id.to_string(),
  })
  id
}

///|
async test "cache RPC reserves immutable keys and selects exact version and ordered prefix restores" {
  with_protocol_fixture((c, pool, root, _, _, clock) => {
    let (a, grant) = artifact_test_start(c)
    assert_eq(
      c.cache_rpc(
        grant.token,
        "GetCacheEntryDownloadURL",
        cache_test_request("deps"),
      ),
      { "ok": false },
    )
    let first = cache_test_save(c, root, grant.token, "deps-a", b"first")
    clock.val += 1L
    ignore(cache_test_save(c, root, grant.token, "deps-b", b"second"))
    ignore(
      cache_test_save(
        c,
        root,
        grant.token,
        "deps-a",
        b"other-version",
        version="v2",
      ),
    )
    assert_true(
      c.cache_rpc(grant.token, "CreateCacheEntry", cache_test_request("deps-a"))
      is { "ok": false, .. },
    )
    let exact = c.cache_rpc(
      grant.token,
      "GetCacheEntryDownloadURL",
      cache_test_request("deps-a"),
    )
    assert_eq(artifact_test_string(exact, "matched_key"), "deps-a")
    let (id, sig) = artifact_test_url(exact, "signed_download_url")
    assert_eq(id, first)
    assert_eq(
      @fs.read_file(c.artifact_blob(root, id, sig).path).text(),
      "first",
    )
    let prefix = c.cache_rpc(grant.token, "GetCacheEntryDownloadURL", {
      "key": "miss",
      "version": "v1",
      "restore_keys": ["missing-", "deps-"],
    })
    assert_eq(artifact_test_string(prefix, "matched_key"), "deps-b")
    assert_eq(
      c.cache_rpc(
        grant.token,
        "GetCacheEntryDownloadURL",
        cache_test_request("deps", version="wrong"),
      ),
      { "ok": false },
    )
    assert_eq(
      c.artifact_rpc(grant.token, "ListArtifacts", artifact_test_request(a, {})),
      { "artifacts": [] },
    )
    pool.with_client(client => {
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
    clock.val += 600001L
    try c.authorize_artifact_blob(id, sig, "read") catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("expired cache capability accepted")
    }
  })
}

///|
async test "cache pending entries stay hidden and cancellation revokes upload and download grants" {
  with_protocol_fixture((c, pool, root, run, _, _) => {
    let (_, grant) = artifact_test_start(c)
    let create = c.cache_rpc(
      grant.token,
      "CreateCacheEntry",
      cache_test_request("pending"),
    )
    let (id, sig) = artifact_test_url(create, "signed_upload_url")
    c.stage_artifact_block(root, id, sig, "YQ==", b"partial")
    assert_eq(
      c.cache_rpc(
        grant.token,
        "GetCacheEntryDownloadURL",
        cache_test_request("pending"),
      ),
      { "ok": false },
    )
    try
      ignore(
        c.cache_rpc(grant.token, "FinalizeCacheEntryUpload", {
          "key": "pending",
          "version": "v1",
          "size_bytes": "7",
        }),
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("published partial cache")
    }
    c.cancel_run(
      @identity.active_user_by_name(pool, "alice"),
      protocol_repo,
      run.number,
    )
    try c.authorize_artifact_blob(id, sig, "write") catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("cancelled cache upload accepted")
    }
  })
}

///|
async test "cache scope is snapshotted and PR caches cannot poison trusted branch or sibling restores" {
  with_protocol_fixture((c, pool, root, run, _, _) => {
    let (_, grant) = artifact_test_start(c)
    ignore(cache_test_save(c, root, grant.token, "trusted", b"trusted"))
    let actor = @identity.active_user_by_name(pool, "alice")
    // A second run/attempt gets a fresh runtime and can restore prior run data.
    let next = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    let second_provider = "d".repeat(64)
    ignore(
      c.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "second",
        second_provider,
        ["self-hosted", "linux"],
        [protocol_repo],
      ),
    )
    let lease = "c".repeat(64)
    let assignment = c
      .claim(second_provider, {
        version: 1,
        runner_os: None,
        request_id: "2".repeat(32),
        attempt_token: lease,
      })
      .unwrap()
    let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
    ignore(c.start(id, lease, 1, execution_id="f".repeat(32)))
    let other = c.artifact_runtime(id, lease, {
      version: 1,
      execution_id: "f".repeat(32),
      origin: "https://moonhub.example",
    })
    // Concurrent attempts in one trusted scope cannot reserve the same key.
    assert_true(
      c.cache_rpc(
        grant.token,
        "CreateCacheEntry",
        cache_test_request("concurrent"),
      )
      is { "ok": true, .. },
    )
    assert_true(
      c.cache_rpc(
        other.token,
        "CreateCacheEntry",
        cache_test_request("concurrent"),
      )
      is { "ok": false, .. },
    )
    let restored = c.cache_rpc(
      other.token,
      "GetCacheEntryDownloadURL",
      cache_test_request("trusted"),
    )
    let (entry, sig) = artifact_test_url(restored, "signed_download_url")
    assert_eq(
      @fs.read_file(c.artifact_blob(root, entry, sig).path).text(),
      "trusted",
    )
    // Model a server-created MR snapshot. Test-only replacement deliberately
    // drops no immutability guard and does not alter trusted run context.
    pool.with_client(client => {
      ignore(
        client.execute("DELETE FROM pipeline_cache_scope WHERE run_id=?", params=[
          next.id,
        ]),
      )
      ignore(
        client.execute("INSERT INTO pipeline_cache_scope VALUES(?,?,?,?)", params=[
          next.id,
          "refs/pull/77/merge",
          "refs/heads/pipeline",
          "refs/heads/pipeline",
        ]),
      )
    })
    ignore(cache_test_save(c, root, other.token, "trusted", b"untrusted"))
    assert_eq(
      artifact_test_string(
        c.cache_rpc(
          grant.token,
          "GetCacheEntryDownloadURL",
          cache_test_request("trusted"),
        ),
        "matched_key",
      ),
      "trusted",
    )
    let trusted = c.cache_rpc(
      grant.token,
      "GetCacheEntryDownloadURL",
      cache_test_request("trusted"),
    )
    let (entry, sig) = artifact_test_url(trusted, "signed_download_url")
    assert_eq(
      @fs.read_file(c.artifact_blob(root, entry, sig).path).text(),
      "trusted",
    )
    let malicious : Json = {
      "key": "trusted",
      "version": "v1",
      "metadata": { "scope": "refs/heads/pipeline" },
    }
    assert_true(
      c.cache_rpc(other.token, "CreateCacheEntry", malicious)
      is { "ok": false, .. },
    )
    // Another MR can read the trusted fallback, but never this MR's cache.
    let own = cache_test_save(c, root, other.token, "pr-only", b"private-pr")
    pool.with_client(client => {
      ignore(
        client.execute("DELETE FROM pipeline_cache_scope WHERE run_id=?", params=[
          next.id,
        ]),
      )
      ignore(
        client.execute("INSERT INTO pipeline_cache_scope VALUES(?,?,?,?)", params=[
          next.id,
          "refs/pull/78/merge",
          "refs/heads/pipeline",
          "refs/heads/pipeline",
        ]),
      )
    })
    assert_eq(
      c.cache_rpc(
        other.token,
        "GetCacheEntryDownloadURL",
        cache_test_request("pr-only"),
      ),
      { "ok": false },
    )
    let trusted_fallback = c.cache_rpc(
      other.token,
      "GetCacheEntryDownloadURL",
      cache_test_request("trusted"),
    )
    let (fallback, _) = artifact_test_url(
      trusted_fallback, "signed_download_url",
    )
    assert_true(fallback != own)
    pool.with_client(client => {
      let scope : String = client
        .query_one("SELECT scope FROM pipeline_cache_scope WHERE run_id=?", params=[
          run.id,
        ])
        .get_name("scope")
      assert_eq(scope, "refs/heads/pipeline")
    })
  })
}

///|
async test "cache capabilities cannot overwrite committed bytes and completed producer data stays readable" {
  with_protocol_fixture((c, pool, root, _, _, _) => {
    let (a, grant) = artifact_test_start(c)
    let create = c.cache_rpc(
      grant.token,
      "CreateCacheEntry",
      cache_test_request("shared"),
    )
    let (id, sig) = artifact_test_url(create, "signed_upload_url")
    assert_true(
      c.cache_rpc(grant.token, "CreateCacheEntry", cache_test_request("shared"))
      is { "ok": true, .. },
    )
    c.stage_artifact_block(root, id, sig, "YQ==", b"original")
    c.commit_artifact_blocks(root, id, sig, ["YQ=="])
    try c.stage_artifact_block(root, id, sig, "YQ==", b"changed") catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("replaced immutable cache bytes")
    }
    ignore(
      c.cache_rpc(grant.token, "FinalizeCacheEntryUpload", {
        "key": "shared",
        "version": "v1",
        "size_bytes": "8",
      }),
    )
    let actor = @identity.active_user_by_name(pool, "alice")
    ignore(
      create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      ),
    )
    let step : @protocol.StepRequest = {
      version: 1,
      step_id: "check",
      state: "running",
      exit_code: 0,
    }
    let producer = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.update_step(producer, attempt_secret, step))
    ignore(
      c.update_step(producer, attempt_secret, { ..step, state: "success", }),
    )
    ignore(
      c.complete(
        @protocol.parse_decimal(a.attempt_id).unwrap(),
        attempt_secret,
        completion(),
      ),
    )
    let lease = "c".repeat(64)
    let next = c
      .claim(provider_secret, claim_request(id="2", secret=lease))
      .unwrap()
    let attempt = @protocol.parse_decimal(next.attempt_id).unwrap()
    ignore(c.start(attempt, lease, 1, execution_id="f".repeat(32)))
    let fresh = c.artifact_runtime(attempt, lease, {
      version: 1,
      execution_id: "f".repeat(32),
      origin: "https://moonhub.example",
    })
    let restored = c.cache_rpc(
      fresh.token,
      "GetCacheEntryDownloadURL",
      cache_test_request("shared"),
    )
    let (_, read_sig) = artifact_test_url(restored, "signed_download_url")
    assert_eq(
      @fs.read_file(c.artifact_blob(root, id, read_sig).path).text(),
      "original",
    )
    assert_true(
      c.cache_rpc(fresh.token, "CreateCacheEntry", cache_test_request("shared"))
      is { "ok": false, .. },
    )
    try
      ignore(
        c.cache_rpc(
          grant.token,
          "GetCacheEntryDownloadURL",
          cache_test_request("shared"),
        ),
      )
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("completed runtime accepted")
    }
  })
}

///|
async test "cache eviction reclaims least recently used data and expiration frees immutable keys" {
  with_protocol_fixture((c, pool, root, _, _, clock) => {
    let (_, grant) = artifact_test_start(c)
    let old = cache_test_save(c, root, grant.token, "old", b"old")
    clock.val += 1L
    let recent = cache_test_save(c, root, grant.token, "recent", b"recent")
    // Fake block accounting rather than allocating a 10 GiB test archive.
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_artifact_block SET size=10737418240 WHERE artifact_id=?",
          params=[old],
        ),
      )
    })
    ignore(cache_test_save(c, root, grant.token, "new", b"new"))
    assert_eq(
      c.cache_rpc(
        grant.token,
        "GetCacheEntryDownloadURL",
        cache_test_request("old"),
      ),
      { "ok": false },
    )
    assert_true(
      c.cache_rpc(
        grant.token,
        "GetCacheEntryDownloadURL",
        cache_test_request("recent"),
      )
      is { "ok": true, .. },
    )
    pool.with_client(client => {
      assert_true(
        client.query_opt("SELECT id FROM pipeline_artifact WHERE id=?", params=[
          old,
        ])
        is None,
      )
      ignore(
        client.execute("UPDATE pipeline_artifact SET expires_ms=? WHERE id=?", params=[
          clock.val,
          recent,
        ]),
      )
    })
    assert_eq(
      c.cache_rpc(
        grant.token,
        "GetCacheEntryDownloadURL",
        cache_test_request("recent"),
      ),
      { "ok": false },
    )
    ignore(cache_test_save(c, root, grant.token, "recent", b"replacement"))
    c.cleanup_artifacts(root)
    pool.with_client(client => {
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "cache entry pressure evicts LRU and pending quota failure rolls eviction back" {
  with_protocol_fixture((c, pool, root, _, _, clock) => {
    let (_, grant) = artifact_test_start(c)
    let old = cache_test_save(c, root, grant.token, "old", b"old")
    clock.val += 1L
    ignore(cache_test_save(c, root, grant.token, "recent", b"recent"))
    pool.with_client(client => {
      // Exercise record limits without creating a thousand physical archives.
      ignore(
        client.execute(
          "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<998) INSERT INTO pipeline_artifact(repository_id,run_id,attempt_id,name,storage_key,state,kind,created_ms,expires_ms) SELECT repository_id,run_id,attempt_id,'filler-' || i,'cache-filler-' || i,'ready','cache',?,expires_ms FROM pipeline_artifact,n WHERE id=?",
          params=[clock.val, old],
        ),
      )
      ignore(
        client.execute(
          "INSERT INTO pipeline_cache(artifact_id,repository_id,scope,key,version,state,created_ms,last_access_ms) SELECT a.id,a.repository_id,c.scope,a.name,c.version,'ready',?,? FROM pipeline_artifact a,pipeline_cache c WHERE c.artifact_id=? AND a.name LIKE 'filler-%'",
          params=[clock.val, clock.val, old],
        ),
      )
    })
    assert_true(
      c.cache_rpc(grant.token, "CreateCacheEntry", cache_test_request("next"))
      is { "ok": true, .. },
    )
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT state FROM pipeline_cache WHERE artifact_id=?", params=[
            old,
          ])
          .get_name("state") : String),
        "deleted",
      )
      assert_eq(
        (
          client
          .query_one(
            "SELECT COUNT(*) AS count FROM pipeline_cache WHERE state <> 'deleted'",
          )
          .get_name("count") : Int64),
        1000L,
      )
      ignore(
        client.execute(
          "UPDATE pipeline_cache SET state='pending' WHERE artifact_id IN (SELECT artifact_id FROM pipeline_cache WHERE key LIKE 'filler-%' LIMIT 99)",
        ),
      )
    })
    try
      ignore(
        c.cache_rpc(
          grant.token,
          "CreateCacheEntry",
          cache_test_request("rejected"),
        ),
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("pending reservation limit ignored")
    }
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one(
            "SELECT COUNT(*) AS count FROM pipeline_cache WHERE state='deleted'",
          )
          .get_name("count") : Int64),
        1L,
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
