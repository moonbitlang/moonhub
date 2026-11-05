///|
fn artifact_test_request(
  assignment : @protocol.Assignment,
  fields : Map[String, Json],
) -> Json {
  let request = fields.copy()
  request["workflow_run_backend_id"] = Json::string(assignment.run_id)
  request["workflow_job_run_backend_id"] = Json::string(assignment.attempt_id)
  Json::object(request)
}

///|
fn artifact_test_string(value : Json, name : String) -> String raise {
  guard value is Object(fields) && fields.get(name) is Some(String(value)) else {
    fail("missing artifact response field: " + name)
  }
  value
}

///|
fn artifact_test_url(value : Json, field : String) -> (Int64, String) raise {
  let url = artifact_test_string(value, field)
  let (path, sig) = url.split_once("?sig=").unwrap()
  (
    @protocol.parse_decimal(path.split("/").last().unwrap().to_owned()).unwrap(),
    sig.to_owned(),
  )
}

///|
fn artifact_test_start(
  c : Coordinator,
) -> (@protocol.Assignment, @protocol.ArtifactRuntime) raise {
  let assignment = c.claim(provider_secret, claim_request()).unwrap()
  let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
  ignore(c.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
  let grant = c.artifact_runtime(id, attempt_secret, {
    version: 1,
    execution_id: "e".repeat(32),
    origin: "https://moonhub.example",
  })
  (assignment, grant)
}

///|
async test "artifact blocks retry without leaking files and finalize verifies archive bytes" {
  with_protocol_fixture((c, pool, root, _, _, _) => {
    let (a, grant) = artifact_test_start(c)
    let request = artifact_test_request(a, { "name": "bundle", "version": 4 })
    let created = c.artifact_rpc(grant.token, "CreateArtifact", request)
    let (id, sig) = artifact_test_url(created, "signed_upload_url")
    let list = artifact_test_request(a, {})
    assert_eq(c.artifact_rpc(grant.token, "ListArtifacts", list), {
      "artifacts": [],
    })
    let key : String = pool.with_client(client => {
      client
      .query_one("SELECT storage_key FROM pipeline_artifact WHERE id=?", params=[
        id,
      ])
      .get_name("storage_key")
    })
    let directory = artifact_directory(root, key)
    c.stage_artifact_block(root, id, sig, "YQ==", b"old")
    c.stage_artifact_block(root, id, sig, "YQ==", b"abc")
    assert_eq(@fs.readdir(directory).length(), 1)
    c.stage_artifact_block(root, id, sig, "Yg==", b"def")
    // Failure to open the assembled archive must not strand the record in assembling.
    @fs.rename(directory, directory + "-offline")
    try c.commit_artifact_blocks(root, id, sig, ["Yg==", "YQ=="]) catch {
      _ => ()
    } noraise {
      _ => fail("commit succeeded without its data directory")
    }
    assert_eq(
      pool.with_client(client => {
        (
          client
          .query_one("SELECT state FROM pipeline_artifact WHERE id=?", params=[
            id,
          ])
          .get_name("state") : String)
      }),
      "pending",
    )
    @fs.rename(directory + "-offline", directory)
    c.commit_artifact_blocks(root, id, sig, ["Yg==", "YQ=="])
    // A lost response can replay the commit safely; reordered bytes cannot.
    c.commit_artifact_blocks(root, id, sig, ["Yg==", "YQ=="])
    try c.commit_artifact_blocks(root, id, sig, ["YQ==", "Yg=="]) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("changed a committed archive")
    }
    let hash = "sha256:" +
      @crypto.bytes_to_hex_string(@crypto.sha256(b"defabc"))
    let finalize = artifact_test_request(a, {
      "name": "bundle",
      "size": "6",
      "hash": hash,
    })
    try
      ignore(
        c.artifact_rpc(
          grant.token,
          "FinalizeArtifact",
          artifact_test_request(a, {
            "name": "bundle",
            "size": "6",
            "hash": "sha256:incorrect",
          }),
        ),
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted incorrect digest")
    }
    assert_eq(c.artifact_rpc(grant.token, "FinalizeArtifact", finalize), {
      "ok": true,
      "artifact_id": id.to_string(),
    })
    assert_eq(c.artifact_rpc(grant.token, "FinalizeArtifact", finalize), {
      "ok": true,
      "artifact_id": id.to_string(),
    })
    let listed = c.artifact_rpc(grant.token, "ListArtifacts", list)
    guard listed is { "artifacts": [artifact], .. } else {
      fail("artifact not listed")
    }
    assert_eq(artifact_test_string(artifact, "digest"), hash)
    assert_eq(artifact_test_string(artifact, "database_id"), id.to_string())
    assert_eq(
      c.artifact_rpc(
        grant.token,
        "ListArtifacts",
        artifact_test_request(a, { "name_filter": "absent" }),
      ),
      { "artifacts": [] },
    )
    let (_, read_sig) = artifact_test_url(
      c.artifact_rpc(
        grant.token,
        "GetSignedArtifactURL",
        artifact_test_request(a, { "name": "bundle" }),
      ),
      "signed_url",
    )
    let blob = c.artifact_blob(root, id, read_sig)
    assert_eq(@fs.read_file(blob.path).text(), "defabc")
    try c.authorize_artifact_blob(id, read_sig, "write") catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("download capability permitted upload")
    }
    try c.authorize_artifact_blob(id, sig, "read") catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("upload capability permitted download")
    }
    let reader = @identity.active_user_by_name(pool, "alice")
    assert_eq(
      c.user_artifact(
        root,
        reader,
        protocol_repo,
        @protocol.parse_decimal(a.run_id).unwrap(),
        id,
      ).path,
      blob.path,
    )
    try
      ignore(
        c.user_artifact(
          root,
          @identity.active_user_by_name(pool, "bob"),
          protocol_repo,
          @protocol.parse_decimal(a.run_id).unwrap(),
          id,
        ),
      )
    catch {
      @domain.NotFound(_) => ()
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("unauthorized browser download")
    }
    ignore(
      c.artifact_rpc(
        grant.token,
        "DeleteArtifact",
        artifact_test_request(a, { "name": "bundle" }),
      ),
    )
    try ignore(c.artifact_blob(root, id, read_sig)) catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("deleted artifact remained readable")
    }
    ignore(c.artifact_rpc(grant.token, "CreateArtifact", request))
    c.cleanup_artifacts(root)
    assert_false(@fs.exists(directory))
  })
}

///|
async test "artifact runtime credentials are execution fenced and separate from lease credentials" {
  with_protocol_fixture((c, pool, _, _, provider, clock) => {
    let (a, grant) = artifact_test_start(c)
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    let request = artifact_test_request(a, {})
    for token in [provider_secret, attempt_secret, grant.token + "x"] {
      try ignore(c.artifact_rpc(token, "ListArtifacts", request)) catch {
        @domain.Unauthorized(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid runtime credential")
      }
    }
    try
      ignore(
        c.artifact_runtime(id, attempt_secret, {
          version: 1,
          execution_id: "f".repeat(32),
          origin: "https://moonhub.example",
        }),
      )
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("another execution minted artifact credential")
    }
    try
      ignore(
        c.artifact_rpc(grant.token, "ListArtifacts", {
          "workflow_run_backend_id": "999",
          "workflow_job_run_backend_id": a.attempt_id,
        }),
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("cross-run metadata access")
    }
    try
      ignore(
        c.artifact_rpc(grant.token, "ListArtifacts", {
          "workflow_run_backend_id": a.run_id,
          "workflow_job_run_backend_id": "999",
        }),
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("forged runtime job")
    }
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT token_hash FROM pipeline_artifact_runtime")
          .get_name("token_hash") : String),
        @identity.hash_token(grant.token),
      )
      assert_false(
        client
        .query_one("SELECT token_hash FROM pipeline_artifact_runtime")
        .get_name("token_hash") ==
        grant.token,
      )
    })
    c.revoke_provider(@identity.active_user_by_name(pool, "admin"), provider.id)
    try ignore(c.artifact_rpc(grant.token, "ListArtifacts", request)) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("revoked provider retained artifact access")
    }
    clock.val += 3600001L
    try ignore(c.artifact_rpc(grant.token, "ListArtifacts", request)) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("expired artifact runtime")
    }
  })
}

///|
async test "later jobs download same-run artifacts while old credentials and other runs cannot" {
  with_protocol_fixture(workflow=dag_workflow, (c, pool, root, _, _, _) => {
    let (build, grant) = artifact_test_start(c)
    let (id, sig) = artifact_test_url(
      c.artifact_rpc(
        grant.token,
        "CreateArtifact",
        artifact_test_request(build, { "name": "cross-job", "version": 4 }),
      ),
      "signed_upload_url",
    )
    c.stage_artifact_block(root, id, sig, "YQ==", b"zip")
    c.commit_artifact_blocks(root, id, sig, ["YQ=="])
    let hash = "sha256:" + @crypto.bytes_to_hex_string(@crypto.sha256(b"zip"))
    ignore(
      c.artifact_rpc(
        grant.token,
        "FinalizeArtifact",
        artifact_test_request(build, {
          "name": "cross-job",
          "size": "3",
          "hash": hash,
        }),
      ),
    )
    let attempt = @protocol.parse_decimal(build.attempt_id).unwrap()
    ignore(
      c.update_step(attempt, attempt_secret, {
        version: 1,
        step_id: "build",
        state: "running",
        exit_code: 0,
      }),
    )
    ignore(
      c.update_step(attempt, attempt_secret, {
        version: 1,
        step_id: "build",
        state: "success",
        exit_code: 0,
      }),
    )
    ignore(c.complete(attempt, attempt_secret, completion()))
    try
      ignore(
        c.artifact_rpc(
          grant.token,
          "ListArtifacts",
          artifact_test_request(build, {}),
        ),
      )
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("completed producer retained access")
    }
    let next = c
      .claim(provider_secret, claim_request(id="2", secret="d".repeat(64)))
      .unwrap()
    let next_id = @protocol.parse_decimal(next.attempt_id).unwrap()
    ignore(c.start(next_id, "d".repeat(64), 1, execution_id="f".repeat(32)))
    let consumer = c.artifact_runtime(next_id, "d".repeat(64), {
      version: 1,
      execution_id: "f".repeat(32),
      origin: "https://moonhub.example",
    })
    guard c.artifact_rpc(
        consumer.token,
        "ListArtifacts",
        artifact_test_request(next, {}),
      )
      is { "artifacts": [_], .. } else {
      fail("cross-job list failed")
    }
    let (_, read_sig) = artifact_test_url(
      c.artifact_rpc(
        consumer.token,
        "GetSignedArtifactURL",
        artifact_test_request(build, { "name": "cross-job" }),
      ),
      "signed_url",
    )
    assert_eq(
      @fs.read_file(c.artifact_blob(root, id, read_sig).path).text(),
      "zip",
    )
    // A second provider can execute an unrelated run concurrently.
    let other_run = create_run(
      pool,
      root,
      @identity.active_user_by_name(pool, "alice"),
      protocol_repo,
      "pipeline",
      ".github/workflows/build.yml",
    )
    let other_provider = "9".repeat(64)
    ignore(
      c.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "other-artifact",
        other_provider,
        ["self-hosted", "linux"],
        [protocol_repo],
      ),
    )
    let other = c
      .claim(other_provider, claim_request(id="3", secret="c".repeat(64)))
      .unwrap()
    assert_eq(other.run_id, other_run.id.to_string())
    let other_id = @protocol.parse_decimal(other.attempt_id).unwrap()
    ignore(c.start(other_id, "c".repeat(64), 1, execution_id="1".repeat(32)))
    let unrelated = c.artifact_runtime(other_id, "c".repeat(64), {
      version: 1,
      execution_id: "1".repeat(32),
      origin: "https://moonhub.example",
    })
    assert_eq(
      c.artifact_rpc(
        unrelated.token,
        "ListArtifacts",
        artifact_test_request(other, {}),
      ),
      { "artifacts": [] },
    )
    try
      ignore(
        c.artifact_rpc(
          unrelated.token,
          "GetSignedArtifactURL",
          artifact_test_request(build, { "name": "cross-job" }),
        ),
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("unrelated run downloaded artifact")
    }
  })
}

///|
async test "artifact storage enforces limits and reaps expired and cascade-orphaned data" {
  with_protocol_fixture((c, pool, root, _, _, clock) => {
    let (a, grant) = artifact_test_start(c)
    let (id, sig) = artifact_test_url(
      c.artifact_rpc(
        grant.token,
        "CreateArtifact",
        artifact_test_request(a, { "name": "limits", "version": 4 }),
      ),
      "signed_upload_url",
    )
    for blocks in [[], ["missing"], ["YQ==", "YQ=="]] {
      try c.commit_artifact_blocks(root, id, sig, blocks) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("invalid block list")
      }
    }
    try c.stage_artifact_block(root, id, sig, "../bad", b"data") catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("block traversal")
    }
    try
      c.stage_artifact_block(
        root,
        id,
        sig,
        "YQ==",
        Bytes::new(maximum_artifact_block_bytes + 1),
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("oversized block accepted")
    }
    c.stage_artifact_block(root, id, sig, "YQ==", b"abc")
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_artifact_block SET size=? WHERE artifact_id=?",
          params=[maximum_artifact_bytes, id],
        ),
      )
    })
    try c.stage_artifact_block(root, id, sig, "Yg==", b"x") catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("artifact quota ignored")
    }
    // The failed request did not leave its temporary block behind.
    let key : String = pool.with_client(client => {
      client
      .query_one("SELECT storage_key FROM pipeline_artifact WHERE id=?", params=[
        id,
      ])
      .get_name("storage_key")
    })
    assert_eq(@fs.readdir(artifact_directory(root, key)).length(), 1)
    let orphan = "d".repeat(64)
    ignore(make_artifact_directory(root, orphan))
    @fs.write_file(artifact_directory(root, orphan) + "/data", b"orphan")
    clock.val += 604800001L
    c.cleanup_artifacts(root)
    assert_false(@fs.exists(artifact_directory(root, key)))
    assert_false(@fs.exists(artifact_directory(root, orphan)))
    pool.with_client(client => {
      assert_true(
        client.query_all("SELECT * FROM pipeline_artifact").is_empty(),
      )
      assert_true(
        client.query_all("SELECT * FROM pipeline_artifact_runtime").is_empty(),
      )
      assert_true(
        client
        .query_all("SELECT * FROM pipeline_artifact_capability")
        .is_empty(),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "artifact capabilities expire independently and cancellation fences all access immediately" {
  with_protocol_fixture((c, pool, root, run, _, clock) => {
    let (a, grant) = artifact_test_start(c)
    let create = artifact_test_request(a, { "name": "fenced", "version": 4 })
    let (id, sig) = artifact_test_url(
      c.artifact_rpc(grant.token, "CreateArtifact", create),
      "signed_upload_url",
    )
    pool.with_client(client => {
      ignore(
        client.execute("UPDATE pipeline_artifact_capability SET expires_ms=?", params=[
          clock.val,
        ]),
      )
    })
    try c.stage_artifact_block(root, id, sig, "YQ==", b"x") catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("expired signed upload accepted")
    }
    // Capability expiry does not revoke the still-live runtime credential.
    assert_eq(
      c.artifact_rpc(grant.token, "ListArtifacts", artifact_test_request(a, {})),
      { "artifacts": [] },
    )
    let attempt = @protocol.parse_decimal(a.attempt_id).unwrap()
    let another = c.artifact_runtime(attempt, attempt_secret, {
      version: 1,
      execution_id: "e".repeat(32),
      origin: "https://moonhub.example",
    })
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_artifact_runtime SET expires_ms=? WHERE token_hash=?",
          params=[clock.val, @identity.hash_token(grant.token)],
        ),
      )
    })
    try
      ignore(
        c.artifact_rpc(
          grant.token,
          "ListArtifacts",
          artifact_test_request(a, {}),
        ),
      )
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("expired runtime accepted")
    }
    assert_eq(
      c.artifact_rpc(
        another.token,
        "ListArtifacts",
        artifact_test_request(a, {}),
      ),
      { "artifacts": [] },
    )
    ignore(
      c.cancel_run(
        @identity.active_user_by_name(pool, "alice"),
        protocol_repo,
        run.number,
      ),
    )
    try
      ignore(
        c.artifact_rpc(
          another.token,
          "ListArtifacts",
          artifact_test_request(a, {}),
        ),
      )
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("cancelled execution retained artifact access")
    }
  })
}
