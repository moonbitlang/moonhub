///|
async test "cross-run artifact API is Actions-read scoped expiring and compatible with upstream v4" {
  @web_testkit.with_repository_test_app(
    (port, pool, root, _, _) => {
      let upstream = @env.get_env_var("MOONHUB_ARTIFACT_UPSTREAM") == Some("1")
      let actor = @identity.active_user_by_name(pool, "alice")
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      ignore(
        @test_support.workflow_commit(
          repo.git_dir(root),
          @test_support.single_job_workflow +
          "\npermissions: {checks: write, actions: read}",
        ),
      )
      let c = @runtime.Coordinator::new(pool)
      let results = @results.Service::new(pool)
      ignore(
        c.create_provider(
          @identity.active_user_by_name(pool, "admin"),
          "cross-artifact",
          "a".repeat(64),
          ["self-hosted", "linux"],
          [repo],
        ),
      )
      let origin = "http://127.0.0.1:\{port}"
      let mut producer_run = 0L
      let mut artifact_id = 0L
      for i in 0..<2 {
        let run = @pipeline.create_run(
          pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
        )
        if i == 0 {
          producer_run = run.public_id
        }
        let lease = ("b" + i.to_string()).repeat(32)
        let a = c
          .claim("a".repeat(64), {
            version: 1,
            request_id: ("c" + i.to_string()).repeat(16),
            attempt_token: lease,
            runner_os: None,
            environments: None,
          })
          .unwrap()
        let attempt = number(a.attempt_id)
        ignore(c.start(attempt, lease, 1, execution_id="d".repeat(32)))
        let api = c.api_runtime(attempt, lease, {
            version: 1,
            execution_id: "d".repeat(32),
          }).token
        let grant = results.artifact_runtime(attempt, lease, {
          version: 1,
          execution_id: "d".repeat(32),
          origin,
        })
        if upstream {
          let directory = root + "/cross-artifact-" + i.to_string()
          @fs.mkdir(directory)
          @fs.mkdir(directory + "/workspace")
          @fs.mkdir(directory + "/temp")
          let dependency = c.dependency_runtime(attempt, lease, {
              version: 1,
              execution_id: "d".repeat(32),
            }).token
          let config : Json = {
            "phase": if i == 0 {
              "produce"
            } else {
              "consume-cross"
            },
            "token": grant.token,
            "api_token": api,
            "dependency_token": dependency,
            "api_permissions": 28,
            "workspace": directory + "/workspace",
            "temp": directory + "/temp",
            "repository": repo.path(),
            "sha": a.commit_sha,
            "run_id": a.run_id,
            "producer_run_id": producer_run.to_string(),
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
                ignore(c.heartbeat(attempt, lease, 1))
              }
            })
            defer heartbeat.cancel()
            @async.with_timeout(180000, () => {
              @process.collect_output_merged("node", [
                "scripts/artifact-upstream-smoke.mjs",
                directory + "/config.json",
              ])
            })
          })
          assert_eq(code, 0, msg=output.text())
          assert_false(output.text().contains(api))
          assert_false(output.text().contains(dependency))
          if i == 0 {
            artifact_id = pool.with_client(client => {
              client
              .query_one(
                "SELECT id FROM pipeline_artifact WHERE name='bin-linux' AND state='ready'",
              )
              .get_name("id")
            })
          }
        } else if i == 0 {
          let fields : Map[String, Json] = {
            "workflow_run_backend_id": a.run_id,
            "workflow_job_run_backend_id": a.attempt_id,
            "name": "fixture",
            "version": 4,
          }
          let created = results.artifact_rpc(
            grant.token,
            "CreateArtifact",
            Json::object(fields),
          )
          guard created is { "signed_upload_url": String(upload), .. } else {
            fail("missing upload grant")
          }
          artifact_id = number(
            upload.split_once("?sig=").unwrap().0
            .split("/")
            .last()
            .unwrap()
            .to_owned(),
          )
          let sig = upload.split_once("?sig=").unwrap().1.to_owned()
          results.stage_artifact_block(
            root, artifact_id, sig, "YQ==", b"archive",
          )
          results.commit_artifact_blocks(root, artifact_id, sig, ["YQ=="])
          fields.remove("version")
          fields["size"] = "7"
          fields["hash"] = "sha256:0eb3e36bfb24dcd9bb1d1bece1531216b59539a8fde17ee80224af0653c92aa3"
          ignore(
            results.artifact_rpc(
              grant.token,
              "FinalizeArtifact",
              Json::object(fields),
            ),
          )
        }
        if i == 1 {
          for prefix in ["/-/api/v1", "/api/v3"] {
            let base = "/repos/alice/demo/actions"
            let (code, listed) = api_test_request(
              port,
              base + "/runs/" + producer_run.to_string() + "/artifacts",
              api,
              None,
              prefix~,
            )
            assert_eq(code, 200, msg=listed.stringify())
            assert_true(listed.stringify().contains("\"expired\":false"))
            assert_eq(
              api_test_request(
                port,
                "/repos/bob/demo/actions/runs/" +
                producer_run.to_string() +
                "/artifacts",
                api,
                None,
                prefix~,
              ).0,
              403,
            )
            let client = @http.Client(origin)
            defer client.close()
            let response = client.get(
              prefix + base + "/artifacts/" + artifact_id.to_string() + "/zip",
              extra_headers={ "Authorization": "Bearer " + api },
            )
            assert_eq(response.code, 302)
            let location = response.headers
              .get("location")
              .unwrap()
              .strip_prefix(origin)
              .unwrap()
              .to_owned()
            ignore(client.read_all())
            assert_eq(client.get(location).code, 200)
            let bytes = client.read_all().binary()
            if !upstream {
              assert_eq(bytes, b"archive")
            } else {
              assert_true(bytes.length() > 0)
            }
            pool.with_client(client => {
              ignore(
                client.execute(
                  "UPDATE pipeline_artifact_api_capability SET expires_ms=0",
                ),
              )
            })
            assert_eq(client.get(location).code, 401)
            ignore(client.read_all())
          }
          // Same-run Twirp never inherits the cross-run REST capability.
          try
            ignore(
              results.artifact_rpc(grant.token, "ListArtifacts", {
                "workflow_run_backend_id": producer_run.to_string(),
                "workflow_job_run_backend_id": a.attempt_id,
              }),
            )
          catch {
            @domain.Forbidden(_) => ()
            err => raise err
          } noraise {
            _ => fail("Twirp escaped run scope")
          }
          pool.with_client(client => {
            ignore(
              client.execute(
                "UPDATE pipeline_artifact SET expires_ms=0 WHERE id=?",
                params=[artifact_id],
              ),
            )
          })
          assert_eq(
            api_test_request(
              port,
              "/repos/alice/demo/actions/runs/" +
              producer_run.to_string() +
              "/artifacts?name=" +
              (if upstream { "bin-linux" } else { "fixture" }),
              api,
              None,
            ).1,
            { "total_count": 0, "artifacts": [] },
          )
          let client = @http.Client(origin)
          defer client.close()
          assert_eq(
            client.get(
              "/api/v3/repos/alice/demo/actions/artifacts/" +
              artifact_id.to_string() +
              "/zip",
              extra_headers={ "Authorization": "Bearer " + api },
            ).code,
            404,
          )
          ignore(client.read_all())
        }
        for state in ["running", "success"] {
          ignore(
            c.update_step(attempt, lease, {
              version: 1,
              step_id: "check",
              state,
              exit_code: 0,
            }),
          )
        }
        ignore(
          c.complete(attempt, lease, {
            version: 1,
            conclusion: "success",
            last_log_sequence: "0",
            outputs: Map([]),
          }),
        )
        assert_eq(
          api_test_request(
            port,
            "/repos/alice/demo/actions/runs/" +
            producer_run.to_string() +
            "/artifacts",
            api,
            None,
          ).0,
          401,
        )
      }
      ignore(
        @test_support.workflow_commit(
          repo.git_dir(root),
          @test_support.single_job_workflow + "\npermissions: {checks: write}",
        ),
      )
      ignore(
        @pipeline.create_run(
          pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
        ),
      )
      let lease = "e".repeat(64)
      let a = c
        .claim("a".repeat(64), {
          version: 1,
          request_id: "f".repeat(32),
          attempt_token: lease,
          runner_os: None,
          environments: None,
        })
        .unwrap()
      let id = number(a.attempt_id)
      ignore(c.start(id, lease, 1, execution_id="a".repeat(32)))
      let token = c.api_runtime(id, lease, {
          version: 1,
          execution_id: "a".repeat(32),
        }).token
      assert_eq(
        api_test_request(
          port,
          "/repos/alice/demo/actions/runs/" +
          producer_run.to_string() +
          "/artifacts",
          token,
          None,
        ).0,
        403,
      )
    },
    release_origin="",
  )
}
