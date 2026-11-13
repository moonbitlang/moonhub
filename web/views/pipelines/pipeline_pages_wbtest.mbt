///|
async test "pipeline pages list runs, show jobs, and cancel with CSRF" {
  @test_support.with_git_test_repo((root, _) => {
    @web_testkit.with_ssh_settings_app(
      (port, pool, alice, _, _) => {
        let repo : @domain.RepoId = { owner: "alice", name: "demo", }
        ignore(
          @test_support.workflow_commit(
            repo.git_dir(root),
            @test_support.single_job_workflow,
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
        let (list_response, list_body) = @web_testkit.http_get_path_with_cookie(
          port, "/alice/demo/pipelines", alice,
        )
        assert_eq(list_response.code, 200)
        assert_true(list_body.contains("Actions"))
        assert_true(list_body.contains("/alice/demo/pipelines/1"))
        let (detail_response, detail_body) = @web_testkit.http_get_path_with_cookie(
          port, "/alice/demo/pipelines/1", alice,
        )
        assert_eq(detail_response.code, 200)
        assert_true(detail_body.contains("Protocol fixture"))
        assert_true(detail_body.contains("build"))
        assert_true(detail_body.contains("name=\"csrf_token\""))
        let csrf = @web_testkit.extract_attr(
          detail_body, "name=\"csrf_token\"", "value=\"",
        )
        let (cancel_response, _) = @web_testkit.http_post_path_with_cookie(
          port,
          "/alice/demo/pipelines/1/cancel",
          "csrf_token=" + csrf,
          alice,
        )
        assert_eq(cancel_response.code, 303)
        let conclusion = @pipeline.get_run(
            pool,
            @identity.active_user_by_name(pool, "alice"),
            repo,
            run.number,
          ).conclusion
        assert_true(conclusion is Some(@pipeline.Cancelled))
      },
      repo_root=root,
    )
  })
}

///|
async test "site admins can create, pause, and revoke pipeline providers" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, admin_cookie) => {
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/pipelines/providers", admin_cookie,
    )
    assert_eq(response.code, 200)
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let (created_response, created_body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/admin/pipelines/providers",
      "csrf_token=" +
      csrf +
      "&name=web-provider&labels=self-hosted%2Clinux&repositories=alice%2Fdemo",
      admin_cookie,
    )
    assert_eq(created_response.code, 200)
    assert_true(created_body.contains("Provider created"))
    assert_true(created_body.contains("web-provider"))
    let provider = @pipeline.Coordinator::new(pool).list_providers(
        @identity.active_user_by_name(pool, "admin"),
      )[0]
    let (paused_response, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/admin/pipelines/providers/" + provider.id.to_string() + "/pause",
      "csrf_token=" + csrf + "&paused=1",
      admin_cookie,
    )
    assert_eq(paused_response.code, 303)
    assert_true(
      @pipeline.Coordinator::new(pool).list_providers(
        @identity.active_user_by_name(pool, "admin"),
      )[0].paused,
    )
    let (revoked_response, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/admin/pipelines/providers/" + provider.id.to_string() + "/revoke",
      "csrf_token=" + csrf,
      admin_cookie,
    )
    assert_eq(revoked_response.code, 303)
    assert_true(
      @pipeline.Coordinator::new(pool).list_providers(
        @identity.active_user_by_name(pool, "admin"),
      )[0].revoked,
    )
  })
}

///|
async test "pipeline polling uses browser authorization cursors and final log completion without page refresh" {
  @test_support.with_git_test_repo((root, _) => {
    @web_testkit.with_ssh_settings_app(
      (port, pool, cookie, bob, _) => {
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
        let coordinator = @pipeline.Coordinator::new(pool)
        ignore(
          coordinator.create_provider(
            @identity.active_user_by_name(pool, "admin"),
            "logs",
            "a".repeat(64),
            ["self-hosted", "linux"],
            [repo],
          ),
        )
        let token = "b".repeat(64)
        let assignment = coordinator
          .claim("a".repeat(64), {
            version: 1,
            runner_os: None,
            request_id: "c".repeat(32),
            attempt_token: token,
          })
          .unwrap()
        let attempt = @protocol.parse_decimal(assignment.attempt_id).unwrap()
        ignore(coordinator.start(attempt, token, 1))
        ignore(
          coordinator.append_log(attempt, token, {
            version: 1,
            sequence: "1",
            step_id: "check",
            stream: "stdout",
            text: "live logs\n",
          }),
        )
        let route = "/alice/demo/pipelines/" + run.number.to_string()
        let logs_path = route + "/attempts/" + assignment.attempt_id + "/logs"
        for endpoint in [route + "/updates", logs_path] {
          let (anonymous, _) = @web_testkit.http_get_path(port, endpoint)
          assert_eq(anonymous.code, 303)
          let (denied, _) = @web_testkit.http_get_path_with_cookie(
            port, endpoint, bob,
          )
          assert_eq(denied.code, 404)
        }
        for after in ["-1", "01", "1e3", "9223372036854775808"] {
          let (invalid, _) = @web_testkit.http_get_path_with_cookie(
            port,
            logs_path + "?after=" + after,
            cookie,
          )
          assert_eq(invalid.code, 400)
        }
        let other = @pipeline.create_run(
          pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
        )
        let (mismatched, _) = @web_testkit.http_get_path_with_cookie(
          port,
          "/alice/demo/pipelines/" +
          other.number.to_string() +
          "/attempts/" +
          assignment.attempt_id +
          "/logs",
          cookie,
        )
        assert_eq(mismatched.code, 404)
        let mut cursor = "0"
        for completed in [false, true] {
          if completed {
            ignore(
              coordinator.complete(attempt, token, {
                version: 1,
                conclusion: "success",
                last_log_sequence: "1",
                outputs: Map([]),
              }),
            )
          }
          let (response, body) = @web_testkit.http_get_path_with_cookie(
            port, route, cookie,
          )
          assert_eq(response.code, 200)
          assert_eq(response.headers.get("refresh"), None)
          assert_true(
            body.contains("data-pipeline-job=\"" + assignment.job_id + "\""),
          )
          assert_true(
            body.contains("data-attempt-id=\"" + assignment.attempt_id + "\""),
          )
          assert_true(body.contains("href=\"/assets/pipeline-logs-"))
          assert_true(body.contains("live logs"))
          let (updates, json) = @web_testkit.http_get_path_with_cookie(
            port,
            route + "/updates",
            cookie,
          )
          assert_eq(updates.code, 200)
          assert_eq(updates.headers.get("cache-control"), Some("no-store"))
          guard @json.parse(json)
            is Object({ "state": String(state), "jobs": Array(jobs), .. }) else {
            fail("invalid run update")
          }
          assert_eq(state, if completed { "completed" } else { "running" })
          assert_eq(jobs.length(), 1)
          guard jobs[0]
            is Object(
              { "id": String(job_id), "attempt_id": String(attempt_id), .. }
            ) else {
            fail("numeric IDs leaked into browser JSON")
          }
          assert_eq(job_id, assignment.job_id)
          assert_eq(attempt_id, assignment.attempt_id)
          let (logs, json) = @web_testkit.http_get_path_with_cookie(
            port,
            logs_path + "?after=" + cursor,
            cookie,
          )
          assert_eq(logs.code, 200)
          assert_eq(logs.headers.get("cache-control"), Some("no-store"))
          guard @json.parse(json)
            is Object(
              {
                "complete": done,
                "next_cursor": String(next),
                "has_more": more,
                "chunks": Array(chunks),
                ..
              }
            ) else {
            fail("invalid log page")
          }
          assert_eq(done, ToJson::to_json(completed))
          assert_eq(more, ToJson::to_json(false))
          assert_eq(chunks.length(), if completed { 0 } else { 1 })
          cursor = next
        }
      },
      repo_root=root,
    )
  })
}
