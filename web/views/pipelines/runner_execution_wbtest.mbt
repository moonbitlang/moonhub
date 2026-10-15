///|
async fn source_status(port : Int32, id : Int64, token : String) -> Int32 {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let response = client.get("/-/runner-api/v1/attempts/\{id}/source", extra_headers={
    "Authorization": "Bearer " + token,
  })
  let body = client.read_all().text()
  assert_true(response.headers.get("cache-control") is Some("no-store"))
  assert_true(!body.contains(token))
  return response.code
}

///|
async test "pull request automatically runs built-in checkout against its merged snapshot" {
  @test_support.with_repository_test_data((pool, root) => {
    @test_support.with_runner_workspace((_, launcher, workspace) => {
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let workflow = @test_support.single_job_workflow
        .replace_all(
          old="on: workflow_dispatch",
          new="on: {pull_request: {types: [opened, synchronize, reopened]}}",
        )
        .replace_all(
          old="steps:\n",
          new="steps:\n      - uses: actions/checkout@v4\n",
        )
        .replace_all(
          old="echo fixture",
          new="test -f README.md; test ! -d .git; grep -q live-output README.md; printf 'live-output\\n'; sleep 0.3; printf 'finished\\n'",
        )
      let dir = repo.git_dir(root)
      let base = @test_support.workflow_commit(dir, workflow)
      ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", base]))
      ignore(
        @test_support.merge_test_commit(dir, "feature", base, "live-output\n"),
      )
      let actor = @identity.active_user_by_name(pool, "alice")
      let scope = @repository.repository_scope(pool, actor, repo)
      let mr = @collaboration.create_merge_request(
        pool, scope, dir, actor, "MR checkout", "", "feature", "master", false,
      )
      assert_true(@pipeline.run_next_merge_check(pool, root))
      let run = @pipeline.list_runs(pool, actor, repo)[0]
      assert_eq(run.workflow_source, workflow)
      let coordinator = @pipeline.Coordinator::new(pool)
      let provider_token = @identity.random_hex(32)
      let attempt_token = @identity.random_hex(32)
      ignore(
        coordinator.create_provider(
          @identity.active_user_by_name(pool, "admin"),
          "runner",
          provider_token,
          ["self-hosted", "linux"],
          [repo],
        ),
      )
      let assignment = coordinator
        .claim(provider_token, {
          version: 1,
          request_id: @identity.random_hex(16),
          attempt_token,
        })
        .unwrap()
      let app = @moonback.App(
        Module(ctx => {
          ctx.mount(
            "/-/runner-api/v1",
            App(
              Module(child => {
                child.provide(@web_context.config_root, root)
                child.provide(
                  @web_context.pipeline_coordinator_key, coordinator,
                )
                child.use_(runner_api_module)
              }),
            ),
          )
        }),
      )
      defer app.close()
      @async.with_task_group(group => {
        let listener = @moonback.listen(port=0)
        let serving = group.spawn(() => app.serve(listener))
        defer serving.cancel()
        assert_eq(
          source_status(
            listener.addr.port(),
            @protocol.parse_decimal(assignment.attempt_id).unwrap(),
            provider_token,
          ),
          401,
        )
        assert_eq(
          source_status(
            listener.addr.port(),
            @protocol.parse_decimal(assignment.attempt_id).unwrap(),
            attempt_token,
          ),
          409,
        )
        let running = group.spawn(() => {
          @runner.run(assignment, attempt_token, {
            server: "http://127.0.0.1:\{listener.addr.port()}",
            workspace,
            launcher,
            allow_http: true,
            unsafe_local: true,
            heartbeat_ms: 50,
          })
        })
        @async.with_timeout(6000, () => {
          while coordinator
                .read_logs(
                  actor,
                  repo,
                  run.number,
                  @protocol.parse_decimal(assignment.attempt_id).unwrap(),
                )
                .is_empty() {
            @async.sleep(10)
          }
        })
        assert_true(
          @pipeline.get_run(pool, actor, repo, run.number).state
          is @pipeline.Running,
        )
        let result = running.wait()
        assert_eq(result.conclusion, "success")
        assert_eq(
          source_status(
            listener.addr.port(),
            @protocol.parse_decimal(assignment.attempt_id).unwrap(),
            attempt_token,
          ),
          409,
        )
        assert_true(result.reported)
        assert_eq(
          @fs.read_file(workspace + "/README.md").text(),
          "live-output\n",
        )
        assert_true(!@fs.exists(workspace + "/.github/workflows/build.yml"))
        assert_eq(
          @collaboration.merge_checks(pool, mr)[0].conclusion,
          "success",
        )
        let logs = coordinator
          .read_logs(
            actor,
            repo,
            run.number,
            @protocol.parse_decimal(assignment.attempt_id).unwrap(),
          )
          .map(chunk => chunk.text)
          .join("")
        assert_eq(
          logs,
          "Checked out pinned source " +
          assignment.commit_sha +
          "\nlive-output\nfinished\n",
        )
        assert_true(!logs.contains(attempt_token))
        let steps = coordinator.read_steps(
          actor,
          repo,
          run.number,
          @protocol.parse_decimal(assignment.attempt_id).unwrap(),
        )
        assert_eq(steps.length(), 2)
        assert_eq(steps[0].state, "success")
        assert_eq(steps[0].exit_code, 0)
        assert_eq(steps[1].state, "success")
        assert_eq(steps[1].exit_code, 0)
      })
    })
  })
}

///|
async test "duplicate runner is fenced while original receives remote cancellation" {
  @test_support.with_repository_test_data((pool, root) => {
    @test_support.with_runner_workspace((local_root, launcher, workspace) => {
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let source = @test_support.single_job_workflow.replace_all(
        old="echo fixture",
        new="touch ready; sleep 20; touch survivor",
      )
      ignore(@test_support.workflow_commit(repo.git_dir(root), source))
      let actor = @identity.active_user_by_name(pool, "alice")
      let run = @pipeline.create_run(
        pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
      )
      let coordinator = @pipeline.Coordinator::new(pool)
      let provider_token = @identity.random_hex(32)
      let attempt_token = @identity.random_hex(32)
      ignore(
        coordinator.create_provider(
          @identity.active_user_by_name(pool, "admin"),
          "runner",
          provider_token,
          ["self-hosted", "linux"],
          [repo],
        ),
      )
      let assignment = coordinator
        .claim(provider_token, {
          version: 1,
          request_id: @identity.random_hex(16),
          attempt_token,
        })
        .unwrap()
      let app = @moonback.App(
        Module(ctx => {
          ctx.mount(
            "/-/runner-api/v1",
            App(
              Module(child => {
                child.provide(@web_context.config_root, root)
                child.provide(
                  @web_context.pipeline_coordinator_key, coordinator,
                )
                child.use_(runner_api_module)
              }),
            ),
          )
        }),
      )
      defer app.close()
      @async.with_task_group(group => {
        let listener = @moonback.listen(port=0)
        let serving = group.spawn(() => app.serve(listener))
        defer serving.cancel()
        let options : @runner.Options = {
          server: "http://127.0.0.1:\{listener.addr.port()}",
          workspace,
          launcher,
          allow_http: true,
          unsafe_local: true,
          heartbeat_ms: 50,
        }
        let original = group.spawn(() => {
          @runner.run(assignment, attempt_token, options)
        })
        @async.with_timeout(6000, () => {
          while !@fs.exists(workspace + "/ready") {
            @async.sleep(10)
          }
        })
        let other = local_root + "/other"
        @fs.mkdir(other)
        let duplicate = @runner.run(assignment, attempt_token, {
          ..options,
          workspace: other,
        })
        assert_eq(duplicate.conclusion, "lost")
        assert_true(!duplicate.reported)
        assert_true(!@fs.exists(other + "/ready"))
        coordinator.cancel_run(actor, repo, run.number)
        let report = @async.with_timeout(6000, () => original.wait())
        assert_eq(report.conclusion, "cancelled")
        assert_true(report.reported)
        assert_true(!@fs.exists(workspace + "/survivor"))
        assert_eq(
          coordinator.read_steps(
            actor,
            repo,
            run.number,
            @protocol.parse_decimal(assignment.attempt_id).unwrap(),
          )[0].state,
          "cancelled",
        )
      })
    })
  })
}
