///|
// Opt-in Windows acceptance uses the production coordinator and HTTP modules.
// A fresh second container verifies cache restore and artifact download.
async test "original Desktop Windows workflow packages uploads and restores with real services" {
  let enabled = @env.get_env_vars().get("MOONHUB_DESKTOP_WINDOWS_SMOKE") ==
    Some("1")
  let source = @env.get_env_vars().get("MOONHUB_OPENSEEK_SOURCE").unwrap_or("")
  let fixture = @fs.read_file(
    "pipeline/workflow/fixtures/openseek-desktop-windows.yml",
  ).text()
  let original = @workflow.parse(fixture)
  let verify_source = @fs.read_file(
    "scripts/fixtures/windows-desktop-verify.yml",
  ).text()
  let verify = @workflow.parse(verify_source).jobs[0]
  let definition : @workflow.Workflow = @json.from_json(
    (
      {
        "name": original.name,
        "jobs": [ToJson::to_json(original.jobs[0]), ToJson::to_json(verify)],
      } : Json),
  )
  let sha = "62a6fba1dccf92c98d4b3c26f5dcf12a5788a8b5"
  @test_support.with_ssh_test_db(pool => {
    let root = @fs.tmpdir(prefix="moonhub-desktop-http-")
    defer @fs.rmdir(root, recursive=true)
    let context : @workflow.RunContext = {
      repository: "alice/demo",
      sha,
      event_name: "pull_request",
      head_ref: "desktop",
      base_ref: "main",
      inputs: Map([]),
      variables: Map([]),
    }
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO pipeline_run(repository_id,number,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,source_ref,definition_version,workflow_source,definition_json,context_json) VALUES(1,1,1,?,?,'desktop',?,'refs/moonhub/pipelines/desktop',?,?,?,?)",
          params=[
            ".github/workflows/desktop-windows.yml",
            original.name,
            sha,
            @workflow.format_version.to_int64(),
            fixture,
            ToJson::to_json(definition).stringify(),
            ToJson::to_json(context).stringify(),
          ],
        ),
      )
      ignore(
        client.execute(
          "INSERT INTO pipeline_cache_scope(run_id,scope,base_scope,default_scope) VALUES(1,'refs/pull/1/merge','refs/heads/main','refs/heads/main')",
        ),
      )
      for ordinal, job in definition.jobs {
        ignore(
          client.execute(
            "INSERT INTO pipeline_job(run_id,job_key,ordinal,status) VALUES(1,?,?,'queued')",
            params=[job.id, ordinal.to_int64()],
          ),
        )
        let id : Int64 = client
          .query_one("SELECT id FROM pipeline_job WHERE job_key=?", params=[
            job.id,
          ])
          .get_name("id")
        for label in job.runs_on {
          ignore(
            client.execute(
              "INSERT INTO pipeline_job_label(job_id,label) VALUES(?,?)",
              params=[id, label],
            ),
          )
        }
      }
    })
    let c = @pipeline.Coordinator::new(pool)
    let provider_token = @identity.random_hex(32)
    ignore(
      c.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "desktop-acceptance",
        provider_token,
        ["self-hosted", "windows", "x64", "windows-2025"],
        [{ owner: "alice", name: "demo", }],
      ),
    )
    let listener = @moonback.listen(port=0)
    let dependencies : @moonback.Module = Module(ctx => {
      ctx.provide(@web_context.pipeline_coordinator_key, c)
      ctx.provide(@web_context.config_root, root)
    })
    let next_token = @identity.random_hex(32)
    let app = @moonback.App(
      Module(ctx => {
        ctx.use_(dependencies)
        ctx.post("/-/acceptance/next", async fn(req, res) {
          guard req.headers.get("authorization") == Some("Bearer " + next_token) else {
            res.send_json(({ "error": "unauthorized" } : Json), status=401)
            return
          }
          let token = @identity.random_hex(32)
          let assignment = c
            .claim(provider_token, {
              version: 1,
              runner_os: Some("windows"),
              request_id: @identity.random_hex(16),
              attempt_token: token,
            })
            .unwrap()
          res.send_json(
            (
              { "assignment": ToJson::to_json(assignment), "token": token } :
              Json),
          )
        })
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
      let server = group.spawn(() => app.serve(listener))
      defer server.cancel()
      if enabled {
        let config : Json = {
          "server": "http://127.0.0.1:" + listener.addr.port().to_string(),
          "token": next_token,
          "source": source,
        }
        let path = root + "/config.json"
        @fs.write_file(path, config.stringify(), permission=0o600)
        let code = @async.with_timeout(4800000, () => {
          @process.run(
            "node",
            ["scripts/openseek-desktop-windows-smoke.mjs", path],
            inherit_env=true,
          )
        })
        assert_eq(code, 0)
      } else {
        // Exercise fixture initialization and both coordinator attempts offline.
        // Network-dependent upstream code remains explicit opt-in.
        for job in definition.jobs {
          let token = @identity.random_hex(32)
          let assignment = c
            .claim(provider_token, {
              version: 1,
              runner_os: Some("windows"),
              request_id: @identity.random_hex(16),
              attempt_token: token,
            })
            .unwrap()
          assert_eq(assignment.job.id, job.id)
          assert_eq(
            assignment.version,
            if job.api_permissions != 0 {
              @protocol.release_assignment_version
            } else {
              @protocol.environment_assignment_version
            },
          )
          let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
          ignore(c.start(id, token, 1, execution_id=@identity.random_hex(16)))
          for step in job.steps {
            for state in ["running", "success"] {
              ignore(
                c.update_step(id, token, {
                  version: 1,
                  step_id: step.id,
                  state,
                  exit_code: 0,
                }),
              )
            }
          }
          ignore(
            c.complete(id, token, {
              version: 1,
              conclusion: "success",
              last_log_sequence: "0",
              outputs: Map([]),
            }),
          )
        }
      }
    })
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one(
            "SELECT COUNT(*) AS count FROM pipeline_job WHERE status='completed' AND conclusion='success'",
          )
          .get_name("count") : Int64),
        2L,
      )
      if enabled {
        assert_eq(
          (
            client
            .query_one(
              "SELECT COUNT(*) AS count FROM pipeline_artifact WHERE kind='artifact' AND state='ready' AND name='SeekMoon-windows-x64'",
            )
            .get_name("count") : Int64),
          1L,
        )
        assert_eq(
          (
            client
            .query_one(
              "SELECT COUNT(*) AS count FROM pipeline_cache WHERE state='ready'",
            )
            .get_name("count") : Int64),
          2L,
        )
      }
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
