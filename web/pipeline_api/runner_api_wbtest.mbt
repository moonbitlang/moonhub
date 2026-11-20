///|
async test "runner module requires injected coordinator rather than reading config" {
  try {
    let app = @moonback.App(runner_api_module)
    app.close()
  } catch {
    @moonback.MissingDependency(name~) =>
      assert_eq(name, "moonhub.pipeline_coordinator")
    err => raise err
  } noraise {
    _ => fail("runner API accepted missing dependencies")
  }
}

///|
async test "production runner mount uses bearer auth never browser sessions and validates bodies" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let token = @identity.random_hex(32)
    let attempt_token = @identity.random_hex(32)
    let coordinator = test_services(pool)
    ignore(
      coordinator.runtime.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "http",
        token,
        ["self-hosted", "linux"],
        [],
      ),
    )
    let request : @protocol.ClaimRequest = {
      environments: None,
      version: 1,
      runner_os: None,
      request_id: @identity.random_hex(16),
      attempt_token,
    }
    let body = ToJson::to_json(request).stringify()
    // Exercise the real wire shape used by current workers, not just legacy
    // clients that omit runner_os. Unknown fields must remain rejected below.
    for os in ["linux", "windows", "macos"] {
      let credential = if os == "linux" {
        token
      } else {
        let credential = @identity.random_hex(32)
        ignore(
          coordinator.runtime.create_provider(
            @identity.active_user_by_name(pool, "admin"),
            "http-" + os,
            credential,
            ["self-hosted", os],
            [],
          ),
        )
        credential
      }
      let (status, result) = @web_testkit.runner_post_json(
        port,
        "/claims",
        ToJson::to_json({ ..request, runner_os: Some(os), }).stringify(),
        token=credential,
      )
      assert_eq(status, 200)
      assert_eq(result, { "version": 1, "assignment": Json::null() })
    }
    assert_eq(@web_testkit.runner_post_json(port, "/claims", body).0, 401)
    assert_eq(
      @web_testkit.runner_post_json(
        port,
        "/claims",
        body,
        cookie="\{alice.name}=\{alice.value}",
      ).0,
      401,
    )
    assert_eq(
      @web_testkit.runner_post_json(port, "/claims", body, token=attempt_token).0,
      401,
    )
    let (status, result) = @web_testkit.runner_post_json(
      port,
      "/claims",
      body,
      token~,
    )
    assert_eq(status, 200)
    assert_eq(result, { "version": 1, "assignment": Json::null() })
    assert_eq(
      @web_testkit.runner_post_json(
        port,
        "/claims",
        body,
        token~,
        content_type="text/plain",
      ).0,
      400,
    )
    assert_eq(
      @web_testkit.runner_post_json(port, "/claims", "{", token~).0,
      400,
    )
    assert_eq(
      @web_testkit.runner_post_json(port, "/claims", "[]", token~).0,
      400,
    )
    assert_eq(
      @web_testkit.runner_post_json(
        port,
        "/claims",
        "{\"version\":1,\"unknown\":true}",
        token~,
      ).0,
      400,
    )
    assert_eq(
      @web_testkit.runner_post_json(
        port,
        "/claims",
        ToJson::to_json({ ..request, version: 99, }).stringify(),
        token~,
      ).0,
      400,
    )
    assert_eq(
      @web_testkit.runner_post_json(port, "/claims", " ".repeat(65537), token~).0,
      413,
    )
    assert_eq(
      @web_testkit.runner_post_json(
        port,
        "/attempts/1/start",
        "{\"version\":1}",
        token~,
      ).0,
      401,
    )
    assert_eq(
      @web_testkit.runner_post_json(
        port,
        "/attempts/not-id/start",
        "{\"version\":1}",
        token~,
      ).0,
      400,
    )
    // Even unexpected database errors must stay on the JSON/redacted boundary.
    pool.with_client(client => {
      client.batch_execute("DROP TABLE pipeline_provider_label")
    })
    let (status, result) = @web_testkit.runner_post_json(
      port,
      "/claims",
      body,
      token~,
    )
    assert_eq(status, 500)
    assert_true(!result.stringify().contains("pipeline_provider_label"))
    assert_true(!result.stringify().contains(token))
    assert_true(!result.stringify().contains(attempt_token))
  })
}

///|
async test "simulated provider completes a real HTTP attempt with retry safe logs and result" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    ignore(
      @test_support.workflow_commit(
        repo.git_dir(root),
        @test_support.single_job_workflow,
      ),
    )
    let actor = @identity.active_user_by_name(pool, "alice")
    let run = @pipeline.create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    let provider_token = @identity.random_hex(32)
    let attempt_token = @identity.random_hex(32)
    let clock = Ref(1700000000000L)
    let coordinator = test_services(pool, clock=() => clock.val)
    ignore(
      coordinator.runtime.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "test",
        provider_token,
        ["self-hosted", "linux"],
        [repo],
      ),
    )
    let app = @moonback.App(
      Module(ctx => {
        ctx.mount(
          "/-/runner-api/v1",
          App(
            Module(child => {
              child.provide(
                @web_context.pipeline_coordinator_key,
                coordinator.runtime,
              )
              child.provide(
                @web_context.pipeline_results_key,
                coordinator.results,
              )
              child.provide(@web_context.pipeline_oidc_key, coordinator.oidc)
              child.use_(runner_api_module)
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
      let port = listener.addr.port()
      let claim : @protocol.ClaimRequest = {
        environments: None,
        version: 1,
        runner_os: None,
        request_id: @identity.random_hex(16),
        attempt_token,
      }
      let (code, json) = @web_testkit.runner_post_json(
        port,
        "/claims",
        ToJson::to_json(claim).stringify(),
        token=provider_token,
      )
      assert_eq(code, 200)
      let assignment : @protocol.Assignment = match json {
        Object(fields) => @json.from_json(fields.get("assignment").unwrap())
        _ => fail("missing assignment")
      }
      assert_eq(assignment.job.steps[0].shell, "")
      assert_eq(assignment.job.steps[0].timeout_minutes, 0)
      let base = "/attempts/\{assignment.attempt_id}"
      assert_eq(@protocol.parse_decimal(assignment.run_id).unwrap(), run.id)
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          "/claims",
          ToJson::to_json(claim).stringify(),
          token=provider_token,
        ).1,
        json,
      )
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          base + "/start",
          "{\"version\":1}",
          token=provider_token,
        ).0,
        401,
      )
      let (code, json) = @web_testkit.runner_post_json(
        port,
        base + "/start",
        "{\"version\":1}",
        token=attempt_token,
      )
      assert_eq(code, 200)
      let started : @protocol.LeaseState = @json.from_json(json)
      assert_eq(started.state, "running")
      assert_eq(started.conclusion, "")
      assert_eq(
        @protocol.parse_decimal(started.deadline_ms).unwrap(),
        clock.val + 60000L,
      )
      assert_eq(
        @protocol.parse_decimal(started.server_time_ms).unwrap(),
        clock.val,
      )
      let (code, json) = @web_testkit.runner_post_json(
        port,
        base + "/heartbeat",
        "{\"version\":1}",
        token=attempt_token,
      )
      assert_eq(code, 200)
      assert_eq((@json.from_json(json) : @protocol.LeaseState).state, "running")
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          base + "/logs",
          "{\"version\":1,\"sequence\":1,\"step_id\":\"check\",\"stream\":\"stdout\",\"text\":\"numeric sequence\"}",
          token=attempt_token,
        ).0,
        400,
      )
      let chunk : @protocol.LogRequest = {
        version: 1,
        sequence: "1",
        step_id: "check",
        stream: "stdout",
        text: "hello <script>\n",
      }
      for sequence in ["", "-1", "+1", " 1", "01", "1e3", "9223372036854775808"] {
        assert_eq(
          @web_testkit.runner_post_json(
            port,
            base + "/logs",
            ToJson::to_json({ ..chunk, sequence, }).stringify(),
            token=attempt_token,
          ).0,
          400,
        )
      }
      let body = ToJson::to_json(chunk).stringify()
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          base + "/logs",
          body,
          token=attempt_token,
        ).0,
        200,
      )
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          base + "/logs",
          body,
          token=attempt_token,
        ).0,
        200,
      )
      assert_eq(
        coordinator.runtime.read_log_page(
          actor,
          repo,
          run.number,
          @protocol.parse_decimal(assignment.attempt_id).unwrap(),
        ).chunks.length(),
        1,
      )
      assert_eq(
        coordinator.runtime.read_log_page(
          actor,
          repo,
          run.number,
          @protocol.parse_decimal(assignment.attempt_id).unwrap(),
        ).chunks[0].text,
        chunk.text,
      )
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          base + "/logs",
          ToJson::to_json({ ..chunk, sequence: "3", }).stringify(),
          token=attempt_token,
        ).0,
        409,
      )
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          base + "/logs",
          ToJson::to_json({ ..chunk, sequence: "2", text: "x".repeat(8193), }).stringify(),
          token=attempt_token,
        ).0,
        413,
      )
      let complete : @protocol.CompleteRequest = {
        version: 1,
        conclusion: "success",
        last_log_sequence: "1",
        outputs: Map([]),
      }
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          base + "/complete",
          "{\"version\":1,\"conclusion\":\"success\",\"last_log_sequence\":1}",
          token=attempt_token,
        ).0,
        400,
      )
      for
        last_log_sequence in [
          "", "-1", "+1", " 1", "01", "1e3", "9223372036854775808",
        ] {
        assert_eq(
          @web_testkit.runner_post_json(
            port,
            base + "/complete",
            ToJson::to_json({ ..complete, last_log_sequence, }).stringify(),
            token=attempt_token,
          ).0,
          400,
        )
      }
      let body = ToJson::to_json(complete).stringify()
      let first = @web_testkit.runner_post_json(
        port,
        base + "/complete",
        body,
        token=attempt_token,
      )
      assert_eq(first.0, 200)
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          base + "/complete",
          body,
          token=attempt_token,
        ).1,
        first.1,
      )
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          base + "/complete",
          ToJson::to_json({ ..complete, conclusion: "failure", }).stringify(),
          token=attempt_token,
        ).0,
        409,
      )
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          base + "/heartbeat",
          "{\"version\":1}",
          token=attempt_token,
        ).0,
        409,
      )
      assert_true(
        @runtime.get_run(pool, actor, repo, run.number).conclusion
        is Some(@runtime.Success),
      )
    })
  })
}

///|
async test "machine modules require each service from the application container" {
  @test_support.with_ssh_test_db(pool => {
    let services = test_services(pool)
    for
      (module_, expected) in [
        (artifact_rpc_module, "moonhub.pipeline_results"),
        (cache_rpc_module, "moonhub.pipeline_results"),
        (artifact_blob_module, "moonhub.pipeline_results"),
        (oidc_module, "moonhub.pipeline_oidc"),
        (runner_api_module, "moonhub.pipeline_results"),
      ] {
      try {
        let app = @moonback.App(
          Module(ctx => {
            ctx.provide(@web_context.pipeline_coordinator_key, services.runtime)
            ctx.use_(module_)
          }),
          config=Config(custom=[
            @moonback.Config::custom(
              @web_context.pipeline_results_key,
              services.results,
            ),
            @moonback.Config::custom(
              @web_context.pipeline_oidc_key,
              services.oidc,
            ),
          ]),
        )
        app.close()
      } catch {
        @moonback.MissingDependency(name~) => assert_eq(name, expected)
        err => raise err
      } noraise {
        _ => fail("machine module read a service from bootstrap configuration")
      }
    }
    try {
      let app = @moonback.App(
        Module(ctx => {
          ctx.provide(@web_context.pipeline_coordinator_key, services.runtime)
          ctx.provide(@web_context.pipeline_results_key, services.results)
          ctx.use_(runner_api_module)
        }),
      )
      app.close()
    } catch {
      @moonback.MissingDependency(name~) =>
        assert_eq(name, "moonhub.pipeline_oidc")
      err => raise err
    } noraise {
      _ => fail("runner module accepted a missing OIDC service")
    }
  })
}
