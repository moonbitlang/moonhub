///|
async test "real runner obtains step secrets through HTTP and stores only masked logs" {
  @test_support.with_repository_test_data((pool, root) => {
    @test_support.with_runner_workspace((_, launcher, workspace) => {
      let (code, node) = @process.collect_output_merged("node", [
        "-p", "process.execPath",
      ])
      assert_eq(code, 0)
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let actor = @identity.active_user_by_name(pool, "alice")
      let workflow = @test_support.single_job_workflow.replace_all(
        old="run: echo fixture",
        new="env: {CREDENTIAL: '${{ secrets.TOKEN }}'}\n        run: printf '%s' \"$CREDENTIAL\"",
      )
      ignore(@test_support.workflow_commit(repo.git_dir(root), workflow))
      @pipeline.save_secret(
        pool,
        root,
        actor,
        @repository.repository_scope(pool, actor, repo),
        "TOKEN",
        Some("http-private-value"),
        "pipeline",
        ".github/workflows/build.yml",
        0L,
      )
      let run = @pipeline.create_run(
        pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
      )
      let coordinator = @pipeline.Coordinator::new(pool)
      let provider = @identity.random_hex(32)
      let token = @identity.random_hex(32)
      ignore(
        coordinator.create_provider(
          @identity.active_user_by_name(pool, "admin"),
          "secret-http",
          provider,
          ["self-hosted", "linux"],
          [repo],
        ),
      )
      let assignment = coordinator
        .claim(provider, {
          environments: None,
          version: 1,
          runner_os: None,
          request_id: @identity.random_hex(16),
          attempt_token: token,
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
        let result = @runner.run(
          assignment,
          token,
          {
            server: "http://127.0.0.1:\{listener.addr.port()}",
            workspace,
            launcher,
            allow_http: true,
            unsafe_local: true,
            linux_ci: false,
            heartbeat_ms: 50,
          },
          action_node=node.text().trim().to_owned(),
          action_runtime=@fs.realpath("runner/actions/runtime.mjs"),
        )
        assert_eq(result.conclusion, "success")
        assert_true(result.reported)
        let logs = coordinator.read_log_page(
            actor,
            repo,
            run.number,
            @protocol.parse_decimal(assignment.attempt_id).unwrap(),
          ).chunks
          .map(chunk => chunk.text)
          .join("")
        assert_eq(logs, "***")
      })
    })
  })
}
