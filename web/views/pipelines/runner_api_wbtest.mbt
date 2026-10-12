///|
async fn post_json(
  port : Int,
  path : String,
  body : String,
  token~ : String = "",
  cookie~ : String = "",
  content_type~ : String = "application/json",
) -> (Int, Json) {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let headers : Map[@http.CaseInsensitiveString, String] = {
    "Content-Type": content_type,
  }
  if !token.is_empty() {
    headers["Authorization"] = "Bearer " + token
  }
  if !cookie.is_empty() {
    headers["Cookie"] = cookie
  }
  let response = client.post(
    "/-/runner-api/v1" + path,
    body,
    extra_headers=headers,
  )
  let text = client.read_all().text()
  assert_true(response.headers.get("cache-control") is Some("no-store"))
  assert_true(response.headers.get("location") is None)
  assert_true(
    response.headers
    .get("content-type")
    .unwrap_or("")
    .has_prefix("application/json"),
  )
  (response.code, @json.parse(text))
}

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
    let coordinator = @pipeline.Coordinator::new(pool)
    ignore(
      coordinator.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "http",
        token,
        ["self-hosted", "linux"],
        [],
      ),
    )
    let request : @protocol.ClaimRequest = {
      version: 1,
      request_id: @identity.random_hex(16),
      attempt_token,
    }
    let body = ToJson::to_json(request).stringify()
    assert_eq(post_json(port, "/claims", body).0, 401)
    assert_eq(
      post_json(port, "/claims", body, cookie="\{alice.name}=\{alice.value}").0,
      401,
    )
    assert_eq(post_json(port, "/claims", body, token=attempt_token).0, 401)
    let (status, result) = post_json(port, "/claims", body, token~)
    assert_eq(status, 200)
    assert_eq(result, { "version": 1, "assignment": Json::null() })
    assert_eq(
      post_json(port, "/claims", body, token~, content_type="text/plain").0,
      400,
    )
    assert_eq(post_json(port, "/claims", "{", token~).0, 400)
    assert_eq(post_json(port, "/claims", "[]", token~).0, 400)
    assert_eq(
      post_json(port, "/claims", "{\"version\":1,\"unknown\":true}", token~).0,
      400,
    )
    assert_eq(
      post_json(
        port,
        "/claims",
        ToJson::to_json({ ..request, version: 99, }).stringify(),
        token~,
      ).0,
      400,
    )
    assert_eq(post_json(port, "/claims", " ".repeat(65537), token~).0, 413)
    assert_eq(
      post_json(port, "/attempts/1/start", "{\"version\":1}", token~).0,
      401,
    )
    assert_eq(
      post_json(port, "/attempts/not-id/start", "{\"version\":1}", token~).0,
      400,
    )
    // Even unexpected database errors must stay on the JSON/redacted boundary.
    pool.with_client(client => {
      client.batch_execute("DROP TABLE pipeline_provider_label")
    })
    let (status, result) = post_json(port, "/claims", body, token~)
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
    let coordinator = @pipeline.Coordinator::new(pool, clock=() => clock.val)
    ignore(
      coordinator.create_provider(
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
              child.provide(@web_context.pipeline_coordinator_key, coordinator)
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
        version: 1,
        request_id: @identity.random_hex(16),
        attempt_token,
      }
      let (code, json) = post_json(
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
        post_json(
          port,
          "/claims",
          ToJson::to_json(claim).stringify(),
          token=provider_token,
        ).1,
        json,
      )
      assert_eq(
        post_json(
          port,
          base + "/start",
          "{\"version\":1}",
          token=provider_token,
        ).0,
        401,
      )
      let (code, json) = post_json(
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
      let (code, json) = post_json(
        port,
        base + "/heartbeat",
        "{\"version\":1}",
        token=attempt_token,
      )
      assert_eq(code, 200)
      assert_eq((@json.from_json(json) : @protocol.LeaseState).state, "running")
      assert_eq(
        post_json(
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
          post_json(
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
        post_json(port, base + "/logs", body, token=attempt_token).0,
        200,
      )
      assert_eq(
        post_json(port, base + "/logs", body, token=attempt_token).0,
        200,
      )
      assert_eq(
        coordinator
        .read_logs(
          actor,
          repo,
          run.number,
          @protocol.parse_decimal(assignment.attempt_id).unwrap(),
        )
        .length(),
        1,
      )
      assert_eq(
        coordinator.read_logs(
          actor,
          repo,
          run.number,
          @protocol.parse_decimal(assignment.attempt_id).unwrap(),
        )[0].text,
        chunk.text,
      )
      assert_eq(
        post_json(
          port,
          base + "/logs",
          ToJson::to_json({ ..chunk, sequence: "3", }).stringify(),
          token=attempt_token,
        ).0,
        409,
      )
      assert_eq(
        post_json(
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
      }
      assert_eq(
        post_json(
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
          post_json(
            port,
            base + "/complete",
            ToJson::to_json({ ..complete, last_log_sequence, }).stringify(),
            token=attempt_token,
          ).0,
          400,
        )
      }
      let body = ToJson::to_json(complete).stringify()
      let first = post_json(port, base + "/complete", body, token=attempt_token)
      assert_eq(first.0, 200)
      assert_eq(
        post_json(port, base + "/complete", body, token=attempt_token).1,
        first.1,
      )
      assert_eq(
        post_json(
          port,
          base + "/complete",
          ToJson::to_json({ ..complete, conclusion: "failure", }).stringify(),
          token=attempt_token,
        ).0,
        409,
      )
      assert_eq(
        post_json(
          port,
          base + "/heartbeat",
          "{\"version\":1}",
          token=attempt_token,
        ).0,
        409,
      )
      assert_true(
        @pipeline.get_run(pool, actor, repo, run.number).conclusion
        is Some(@pipeline.Success),
      )
    })
  })
}
