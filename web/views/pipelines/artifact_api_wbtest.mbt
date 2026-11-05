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
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    ignore(
      @test_support.workflow_commit(repo.git_dir(root), artifact_http_workflow),
    )
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
    ignore(
      @pipeline.create_run(
        pool,
        root,
        @identity.active_user_by_name(pool, "alice"),
        repo,
        "pipeline",
        ".github/workflows/build.yml",
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
async test "upstream Artifact v4 actions upload overwrite and download across jobs" {
  guard @env.get_env_vars().get("MOONHUB_ARTIFACT_UPSTREAM") == Some("1") else {
    return
  }
  with_artifact_http((port, c, pool, _, first, lease) => {
    let root = @fs.tmpdir(prefix="moonhub-artifact-upstream-")
    defer @fs.rmdir(root, recursive=true)
    let origin = "http://127.0.0.1:\{port}"
    let script = @fs.realpath("scripts/artifact-upstream-smoke.mjs")
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
