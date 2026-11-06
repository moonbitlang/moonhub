///|
let artifact_http_workflow : String =
  #|name: Artifact acceptance
  #|on: workflow_dispatch
  #|jobs:
  #|  produce:
  #|    runs-on: self-hosted
  #|    steps:
  #|      - id: produce
  #|        run: echo produce
  #|  consume:
  #|    needs: produce
  #|    runs-on: self-hosted
  #|    steps:
  #|      - id: consume
  #|        run: echo consume

///|
async fn with_artifact_http(
  f : async (
    Int32,
    @pipeline.Coordinator,
    @database.Database,
    String,
    @protocol.Assignment,
    String,
  ) -> Unit,
  workflow~ : String = artifact_http_workflow,
  inputs~ : Map[String, Json] = Map([]),
  variables~ : Map[String, String] = Map([]),
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    ignore(@test_support.workflow_commit(repo.git_dir(root), workflow))
    let c = @pipeline.Coordinator::new(pool)
    let token = "a".repeat(64)
    ignore(
      c.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "artifacts",
        token,
        ["self-hosted", "linux"],
        [repo],
      ),
    )
    for name, value in variables {
      @pipeline.save_variable(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        repo,
        name,
        value,
        0L,
      )
    }
    ignore(
      @pipeline.create_run(
        pool,
        root,
        @identity.active_user_by_name(pool, "alice"),
        repo,
        "pipeline",
        ".github/workflows/build.yml",
        inputs~,
      ),
    )
    let lease = "b".repeat(64)
    let assignment = c
      .claim(token, {
        version: 1,
        runner_os: None,
        request_id: "1".repeat(32),
        attempt_token: lease,
      })
      .unwrap()
    let dependencies : @moonback.Module = Module(ctx => {
      ctx.provide(@web_context.pipeline_coordinator_key, c)
      ctx.provide(@web_context.config_root, root)
    })
    let app = @moonback.App(
      Module(ctx => {
        ctx.mount(
          "/-/runner-api/v1",
          App(
            Module(child => {
              child.use_(dependencies)
              child.use_(runner_api_module)
            }),
          ),
        )
        ctx.mount(
          "/twirp/github.actions.results.api.v1.ArtifactService",
          App(
            Module(child => {
              child.use_(dependencies)
              child.use_(artifact_rpc_module)
            }),
          ),
        )
        ctx.mount(
          "/twirp/github.actions.results.api.v1.CacheService",
          App(
            Module(child => {
              child.use_(dependencies)
              child.use_(cache_rpc_module)
            }),
          ),
        )
        ctx.mount(
          "/-/artifact-blobs",
          App(
            Module(child => {
              child.use_(dependencies)
              child.use_(artifact_blob_module)
            }),
          ),
        )
      }),
    )
    defer app.close()
    @async.with_task_group(group => {
      let listener = @moonback.listen(port=0)
      let server = group.spawn(() => app.serve(listener))
      defer server.cancel()
      f(listener.addr.port(), c, pool, root, assignment, lease)
    })
  })
}

///|
async test "artifact HTTP mounts validate credentials Twirp fields and Azure block operations" {
  with_artifact_http((port, c, _, _, a, lease) => {
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    let execution = "e".repeat(32)
    ignore(c.start(id, lease, 1, execution_id=execution))
    let origin = "http://127.0.0.1:\{port}"
    let (status, granted) = post_json(
      port,
      "/attempts/" + a.attempt_id + "/artifact-runtime",
      ToJson::to_json(@protocol.ArtifactRuntimeRequest::{
        version: 1,
        execution_id: execution,
        origin,
      }).stringify(),
      token=lease,
    )
    assert_eq(status, 200)
    let grant : @protocol.ArtifactRuntime = @json.from_json(granted)
    let client = @http.Client(origin)
    defer client.close()
    let endpoint = "/twirp/github.actions.results.api.v1.ArtifactService/"
    let request : Json = {
      "workflow_run_backend_id": a.run_id,
      "workflow_job_run_backend_id": a.attempt_id,
      "name": "http",
      "version": 4,
    }
    let bad = client.post(endpoint + "CreateArtifact", request.stringify(), extra_headers={
      "Content-Type": "application/json",
      "Authorization": "Bearer " + lease,
    })
    assert_eq(bad.code, 401)
    assert_true(client.read_all().json() is { "code": "unauthenticated", .. })
    let response = client.post(
      endpoint + "CreateArtifact",
      request.stringify(),
      extra_headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer " + grant.token,
      },
    )
    assert_eq(response.code, 200)
    guard client.read_all().json() is { "signed_upload_url": String(url), .. } else {
      fail("missing upload URL")
    }
    let path = url.strip_prefix(origin).unwrap().to_owned()
    let upload = client.put(path + "&comp=block&blockid=YQ%3D%3D", b"archive")
    assert_eq(upload.code, 201)
    ignore(client.read_all())
    let commit = client.put(
      path + "&comp=blocklist",
      "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList><Latest>YQ==</Latest></BlockList>",
    )
    assert_eq(commit.code, 201)
    assert_true(commit.headers.get("etag") is Some(_))
    ignore(client.read_all())
    let oversized = client.put(path + "&comp=blocklist", " ".repeat(65537))
    assert_eq(oversized.code, 413)
    ignore(client.read_all())
  })
}

///|
test "Azure block list parser rejects arbitrary XML and preserves block order" {
  assert_eq(
    artifact_block_list(
      "<?xml version=\"1.0\"?><BlockList><Latest>Yg==</Latest><Latest>YQ==</Latest></BlockList>",
    ),
    ["Yg==", "YQ=="],
  )
  for
    text in [
      "<BlockList><Latest>YQ==</Latest><Other/></BlockList>", "<!DOCTYPE x><BlockList></BlockList>",
      "<BlockList><Latest>&x;</Latest></BlockList>", "<BlockList><Latest>../bad</Latest></BlockList>",
      "<BlockList></BlockList>tail",
    ] {
    try ignore(artifact_block_list(text)) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted invalid block list")
    }
  }
}

///|
// Network opt-in: run unmodified, pinned upstream v4 Actions against the actual
// HTTP service, with producer and consumer credentials from separate attempts.
async fn upstream_service_smoke(enabled : String, script_name : String) -> Unit {
  guard @env.get_env_vars().get(enabled) == Some("1") else { return }
  with_artifact_http((port, c, pool, _, first, lease) => {
    let root = @fs.tmpdir(prefix="moonhub-artifact-upstream-")
    defer @fs.rmdir(root, recursive=true)
    let origin = "http://127.0.0.1:\{port}"
    let script = @fs.realpath("scripts/" + script_name)
    for phase in ["produce", "consume"] {
      let token = if phase == "produce" { lease } else { "d".repeat(64) }
      let a = if phase == "produce" {
        first
      } else {
        c
        .claim("a".repeat(64), {
          version: 1,
          runner_os: None,
          request_id: "2".repeat(32),
          attempt_token: token,
        })
        .unwrap()
      }
      let attempt = @protocol.parse_decimal(a.attempt_id).unwrap()
      let execution = @identity.random_hex(16)
      ignore(c.start(attempt, token, 1, execution_id=execution))
      let grant = c.artifact_runtime(attempt, token, {
        version: 1,
        execution_id: execution,
        origin,
      })
      let directory = root + "/" + phase
      @fs.mkdir(directory)
      @fs.mkdir(directory + "/workspace")
      @fs.mkdir(directory + "/temp")
      let config : Json = {
        "phase": phase,
        "token": grant.token,
        "workspace": directory + "/workspace",
        "temp": directory + "/temp",
        "repository": "alice/demo",
        "sha": a.commit_sha,
        "run_id": a.run_id,
        "attempt_id": a.attempt_id,
        "server": origin,
      }
      @fs.write_file(
        directory + "/config.json",
        config.stringify(),
        permission=0o600,
      )
      let (code, output) = @async.with_task_group(group => {
        let heartbeat : @async.Task[Unit] = group.spawn(() => {
          for ;; {
            @async.sleep(5000)
            ignore(c.heartbeat(attempt, token, 1))
          }
        })
        defer heartbeat.cancel()
        @async.with_timeout(180000, () => {
          @process.collect_output_merged("node", [
            script,
            directory + "/config.json",
          ])
        })
      })
      assert_eq(code, 0, msg=output.text())
      assert_false(output.text().contains(grant.token))
      assert_false(output.text().contains("http://moonhub.localhost/"))
      let request : @protocol.StepRequest = {
        version: 1,
        step_id: phase,
        state: "running",
        exit_code: 0,
      }
      ignore(c.update_step(attempt, token, request))
      ignore(c.update_step(attempt, token, { ..request, state: "success", }))
      ignore(
        c.complete(attempt, token, {
          version: 1,
          conclusion: "success",
          last_log_sequence: "0",
          outputs: Map([]),
        }),
      )
    }
    pool.with_client(client => {
      let row = client.query_one(
        "SELECT COUNT(*) AS count FROM pipeline_artifact WHERE state='ready'",
      )
      assert_eq((row.get_name("count") : Int64), 2L)
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "production artifact mounts keep browser downloads repository authorized after job completion" {
  @web_testkit.with_repository_test_app((port, pool, root, alice, bob) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    ignore(
      @test_support.workflow_commit(
        repo.git_dir(root),
        @test_support.single_job_workflow,
      ),
    )
    let c = @pipeline.Coordinator::new(pool)
    ignore(
      c.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "browser-artifact",
        "a".repeat(64),
        ["self-hosted", "linux"],
        [repo],
      ),
    )
    let run = @pipeline.create_run(
      pool,
      root,
      @identity.active_user_by_name(pool, "alice"),
      repo,
      "pipeline",
      ".github/workflows/build.yml",
    )
    let a = c
      .claim("a".repeat(64), {
        version: 1,
        runner_os: None,
        request_id: "1".repeat(32),
        attempt_token: "b".repeat(64),
      })
      .unwrap()
    let attempt = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.start(attempt, "b".repeat(64), 1, execution_id="e".repeat(32)))
    let origin = "http://127.0.0.1:\{port}"
    let grant = c.artifact_runtime(attempt, "b".repeat(64), {
      version: 1,
      execution_id: "e".repeat(32),
      origin,
    })
    let client = @http.Client(origin)
    defer client.close()
    let endpoint = "/twirp/github.actions.results.api.v1.ArtifactService/"
    let fields : Map[String, Json] = {
      "workflow_run_backend_id": Json::string(a.run_id),
      "workflow_job_run_backend_id": Json::string(a.attempt_id),
      "name": "browser",
    }
    let create = fields.copy()
    create["version"] = 4
    assert_eq(
      client.post(
        endpoint + "CreateArtifact",
        Json::object(create).stringify(),
        extra_headers={
          "Content-Type": "application/json",
          "Authorization": "Bearer " + grant.token,
        },
      ).code,
      200,
    )
    guard client.read_all().json()
      is { "signed_upload_url": String(upload), .. } else {
      fail("missing upload URL")
    }
    let sig = upload.split_once("?sig=").unwrap().1.to_owned()
    let id = @protocol.parse_decimal(
      upload.split_once("?sig=").unwrap().0
      .split("/")
      .last()
      .unwrap()
      .to_owned(),
    ).unwrap()
    c.stage_artifact_block(root, id, sig, "YQ==", b"archive")
    c.commit_artifact_blocks(root, id, sig, ["YQ=="])
    let finalize = fields.copy()
    finalize["size"] = "7"
    finalize["hash"] = "sha256:0eb3e36bfb24dcd9bb1d1bece1531216b59539a8fde17ee80224af0653c92aa3"
    let _ = c.artifact_rpc(
      grant.token,
      "FinalizeArtifact",
      Json::object(finalize),
    )
    ignore(
      c.update_step(attempt, "b".repeat(64), {
        version: 1,
        step_id: "check",
        state: "running",
        exit_code: 0,
      }),
    )
    ignore(
      c.update_step(attempt, "b".repeat(64), {
        version: 1,
        step_id: "check",
        state: "success",
        exit_code: 0,
      }),
    )
    ignore(
      c.complete(attempt, "b".repeat(64), {
        version: 1,
        conclusion: "success",
        last_log_sequence: "0",
        outputs: Map([]),
      }),
    )
    let path = "/alice/demo/actions/runs/\{run.id}/artifacts/\{id}"
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port, path, alice,
    )
    assert_eq(response.code, 200)
    assert_eq(body, "archive")
    assert_true(
      response.headers
      .get("content-disposition")
      .unwrap_or("")
      .has_prefix("attachment;"),
    )
    assert_true(
      response.headers.get("cache-control") is Some("private, no-store"),
    )
    assert_eq(
      @web_testkit.http_get_path_with_cookie(port, path, bob).0.code,
      404,
    )
    assert_true(@web_testkit.http_get_path(port, path).0.code != 200)
    assert_eq(
      @web_testkit.http_get_path_with_cookie(
        port,
        "/alice/demo/actions/runs/999/artifacts/\{id}",
        alice,
      ).0.code,
      404,
    )
    // Machine routes never accept browser cookies in lieu of runtime credentials.
    assert_eq(
      client.post(endpoint + "ListArtifacts", "{}", extra_headers={
        "Content-Type": "application/json",
        "Cookie": alice.name + "=" + alice.value,
      }).code,
      401,
    )
    ignore(client.read_all())
  })
}

///|
priv struct ArtifactTestWriter {
  blocked : @async.Semaphore
  bytes : @buffer.Buffer
  stall : Bool
}

///|
impl @io.Writer for ArtifactTestWriter with fn write_once(
  self,
  data,
  offset~,
  len~,
) {
  if self.stall {
    self.blocked.acquire()
  }
  self.bytes.write_bytes(data[offset:offset + len])
  len
}

///|
async test "artifact streams time out stalled writers and release transfer capacity" {
  let root = @fs.tmpdir(prefix="moonhub-artifact-stream-")
  defer @fs.rmdir(root, recursive=true)
  @fs.write_file(root + "/zip", b"archive")
  let file = @fs.open(root + "/zip", mode=ReadOnly)
  defer file.close()
  let transfers = @async.Semaphore(1)
  let writer : ArtifactTestWriter = {
    blocked: @async.Semaphore(1, initial_value=0),
    bytes: @buffer.Buffer(),
    stall: true,
  }
  try
    with_artifact_transfer(transfers, () => (), () => {
      stream_artifact(file, writer, () => (), timeout_ms=10)
    })
  catch {
    @async.TimeoutError => ()
    err => raise err
  } noraise {
    _ => fail("stalled writer retained transfer capacity")
  }
  assert_true(transfers.try_acquire())
  transfers.release()
  assert_true(writer.bytes.is_empty())
}

///|
async test "artifact transfers bound queue waits and reauthorize before sending bytes" {
  let transfers = @async.Semaphore(1)
  transfers.acquire()
  let entered = Ref(false)
  try
    with_artifact_transfer(
      transfers,
      () => (),
      () => entered.val = true,
      timeout_ms=10,
    )
  catch {
    @async.TimeoutError => ()
    err => raise err
  } noraise {
    _ => fail("unbounded transfer queue")
  }
  assert_false(entered.val)
  transfers.release()
  @async.with_task_group(group => {
    let started = @async.Semaphore(1, initial_value=0)
    let authorized = Ref(true)
    transfers.acquire()
    let waiter = group.spawn(async fn() -> Unit {
      started.release()
      try
        with_artifact_transfer(
          transfers,
          () => {
            if !authorized.val {
              raise @domain.Unauthorized(message="expired while queued")
            }
          },
          () => entered.val = true,
        )
      catch {
        @domain.Unauthorized(_) => ()
        err => raise err
      } noraise {
        _ => fail("queued capability was not rechecked")
      }
    })
    // Hold the only slot until the request is waiting; then revoke it.
    started.acquire()
    @async.sleep(1)
    authorized.val = false
    transfers.release()
    waiter.wait()
  })
  assert_false(entered.val)
  assert_true(transfers.try_acquire())
  transfers.release()
}

///|
async test "artifact streams stop on authorization revocation before the next chunk" {
  let root = @fs.tmpdir(prefix="moonhub-artifact-revoke-stream-")
  defer @fs.rmdir(root, recursive=true)
  @fs.write_file(root + "/zip", Bytes::make(65537, 0x61))
  let file = @fs.open(root + "/zip", mode=ReadOnly)
  defer file.close()
  let writer : ArtifactTestWriter = {
    blocked: @async.Semaphore(1),
    bytes: @buffer.Buffer(),
    stall: false,
  }
  let calls = Ref(0)
  try
    stream_artifact(file, writer, () => {
      calls.val += 1
      if calls.val > 1 {
        raise @domain.Unauthorized(message="revoked")
      }
    })
  catch {
    @domain.Unauthorized(_) => ()
    err => raise err
  } noraise {
    _ => fail("revoked stream continued")
  }
  assert_eq(writer.bytes.length(), 65536)
}

///|
async test "upstream Artifact v4 actions upload overwrite and download across jobs" {
  upstream_service_smoke(
    "MOONHUB_ARTIFACT_UPSTREAM", "artifact-upstream-smoke.mjs",
  )
}

///|
async test "upstream Cache v4 actions save in post and restore exact prefix and lookup hits across jobs" {
  upstream_service_smoke("MOONHUB_CACHE_UPSTREAM", "cache-upstream-smoke.mjs")
}

///|
async test "Cache HTTP authenticates RPCs handles single PUT replay and accepts Azure SDK sized blocks" {
  with_artifact_http((port, c, _, _, a, lease) => {
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.start(id, lease, 1, execution_id="e".repeat(32)))
    let origin = "http://127.0.0.1:\{port}"
    let grant = c.artifact_runtime(id, lease, {
      version: 1,
      execution_id: "e".repeat(32),
      origin,
    })
    let client = @http.Client(origin)
    defer client.close()
    let endpoint = "/twirp/github.actions.results.api.v1.CacheService/"
    let payload : Json = { "key": "http-cache", "version": "v1" }
    assert_eq(
      client.post(endpoint + "CreateCacheEntry", payload.stringify(), extra_headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer " + lease,
      }).code,
      401,
    )
    ignore(client.read_all())
    let headers : Map[@http.CaseInsensitiveString, String] = {
      "Content-Type": "application/json",
      "Authorization": "Bearer " + grant.token,
    }
    assert_eq(
      client.post(
        endpoint + "CreateCacheEntry",
        payload.stringify(),
        extra_headers=headers,
      ).code,
      200,
    )
    guard client.read_all().json() is { "signed_upload_url": String(url), .. } else {
      fail("missing upload capability")
    }
    let path = url.strip_prefix(origin).unwrap().to_owned()
    assert_eq(client.put(path, b"single-body").code, 201)
    ignore(client.read_all())
    assert_eq(client.put(path, b"single-body").code, 201)
    ignore(client.read_all())
    assert_eq(
      client.post(
        endpoint + "FinalizeCacheEntryUpload",
        "{\"key\":\"http-cache\",\"version\":\"v1\",\"size_bytes\":\"11\"}",
        extra_headers=headers,
      ).code,
      200,
    )
    assert_true(client.read_all().json() is { "ok": true, .. })
    assert_eq(
      client.post(
        endpoint + "GetCacheEntryDownloadURL",
        payload.stringify(),
        extra_headers=headers,
      ).code,
      200,
    )
    guard client.read_all().json() is { "signed_download_url": String(url), .. } else {
      fail("missing download capability")
    }
    assert_eq(
      client.get(url.strip_prefix(origin).unwrap().to_owned()).code,
      200,
    )
    assert_eq(client.read_all().text(), "single-body")
    let second : Json = { "key": "block-cache", "version": "v1" }
    assert_eq(
      client.post(
        endpoint + "CreateCacheEntry",
        second.stringify(),
        extra_headers=headers,
      ).code,
      200,
    )
    guard client.read_all().json() is { "signed_upload_url": String(url), .. } else {
      fail("missing block capability")
    }
    let path = url.strip_prefix(origin).unwrap().to_owned()
    let large = "z".repeat(9 * 1024 * 1024)
    assert_eq(
      client.put(path + "&comp=block&blockid=YQ%3D%3D", large).code,
      201,
    )
    ignore(client.read_all())
    assert_eq(
      client.put(path + "&comp=block&blockid=Yg%3D%3D", b"tail").code,
      201,
    )
    ignore(client.read_all())
    assert_eq(
      client.put(
        path + "&comp=blocklist",
        "<BlockList><Latest>YQ==</Latest><Latest>Yg==</Latest></BlockList>",
      ).code,
      201,
    )
    ignore(client.read_all())
    let size = (9 * 1024 * 1024 + 4).to_string()
    let finalize : Json = {
      "key": "block-cache",
      "version": "v1",
      "size_bytes": size,
    }
    assert_eq(
      client.post(
        endpoint + "FinalizeCacheEntryUpload",
        finalize.stringify(),
        extra_headers=headers,
      ).code,
      200,
    )
    assert_true(client.read_all().json() is { "ok": true, .. })
  })
}
