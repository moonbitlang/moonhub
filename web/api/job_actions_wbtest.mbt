///|
async test "job PR metadata and owned check writes enforce scopes commit identity lifetime and both mounts" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let sha = @test_support.workflow_commit(
      repo.git_dir(root),
      @test_support.single_job_workflow +
      "\npermissions: {pull-requests: write, checks: write, actions: read}",
    )
    ignore(
      @test_support.merge_test_commit(
        repo.git_dir(root),
        "automation",
        @gitops.branch_sha(repo.git_dir(root), "master"),
        "automation change\n",
      ),
    )
    let mr = @collaboration.create_merge_request(
      pool,
      scope,
      repo.git_dir(root),
      actor,
      "Automation PR",
      "original",
      "automation",
      "master",
      false,
    )
    let c = @runtime.Coordinator::new(pool)
    ignore(
      c.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "job-api",
        "a".repeat(64),
        ["self-hosted", "linux"],
        [repo],
      ),
    )
    let mut first_check = 0L
    let mut first_token = ""
    for i in 0..<3 {
      if i == 2 {
        ignore(
          @test_support.workflow_commit(
            repo.git_dir(root),
            @test_support.single_job_workflow + "\npermissions: {actions: read}",
          ),
        )
      }
      ignore(
        @pipeline.create_run(
          pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
        ),
      )
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
      let id = number(a.attempt_id)
      ignore(c.start(id, lease, 1, execution_id="d".repeat(32)))
      let token = c.api_runtime(id, lease, {
          version: 1,
          execution_id: "d".repeat(32),
        }).token
      if i < 2 {
        assert_eq(a.version, 18)
      }
      for prefix in ["/-/api/v1", "/api/v3"] {
        let (status, _) = api_test_request(
          port,
          "/repos/alice/demo/pulls/" + mr.number.to_string(),
          token,
          Some({ "title": "Updated via job", "body": "automation metadata" }),
          verb=Patch,
          prefix~,
        )
        assert_eq(status, if i == 2 { 403 } else { 200 })
        let fields : Json = {
          "name": "coverage",
          "head_sha": sha,
          "status": "in_progress",
          "output": { "title": "Coverage", "summary": "## report " + token },
        }
        let (status, created) = api_test_request(
          port,
          "/repos/alice/demo/check-runs",
          token,
          Some(fields),
          prefix~,
        )
        assert_eq(
          status,
          if i == 2 {
            403
          } else {
            201
          },
          msg=created.stringify(),
        )
        if i < 2 {
          guard created is { "id": Number(check_id, ..), .. } else {
            fail("missing check")
          }
          let check_id = check_id.to_int64()
          assert_false(created.stringify().contains(token))
          assert_eq(
            api_test_request(
              port,
              "/repos/alice/demo/check-runs/" + check_id.to_string(),
              token,
              Some({ "conclusion": "success" }),
              verb=Patch,
              prefix~,
            ).0,
            200,
          )
          assert_eq(
            api_test_request(
              port,
              "/repos/alice/demo/check-runs",
              token,
              Some({ "name": "wrong", "head_sha": "f".repeat(40) }),
              prefix~,
            ).0,
            422,
          )
          assert_eq(
            api_test_request(
              port,
              "/repos/bob/demo/check-runs",
              token,
              Some(fields),
              prefix~,
            ).0,
            403,
          )
          let (listed, checks) = api_test_request(
            port,
            "/repos/alice/demo/commits/" + sha + "/check-runs",
            token,
            None,
            prefix~,
          )
          assert_eq(listed, 200)
          assert_true(checks.stringify().contains("\"writer\""))
          if i == 0 {
            first_check = check_id
            first_token = token
          } else {
            assert_eq(
              api_test_request(
                port,
                "/repos/alice/demo/check-runs/" + first_check.to_string(),
                token,
                Some({ "conclusion": "failure" }),
                verb=Patch,
                prefix~,
              ).0,
              403,
            )
          }
        }
      }
      for state in ["running", "success"] {
        ignore(
          c.update_step(id, lease, {
            version: 1,
            step_id: "check",
            state,
            exit_code: 0,
          }),
        )
      }
      ignore(
        c.complete(id, lease, {
          version: 1,
          conclusion: "success",
          last_log_sequence: "0",
          outputs: Map([]),
        }),
      )
    }
    assert_eq(
      api_test_request(
        port,
        "/repos/alice/demo/pulls/" + mr.number.to_string(),
        first_token,
        Some({ "title": "expired" }),
        verb=Patch,
      ).0,
      401,
    )
    assert_eq(
      api_test_request(
        port,
        "/repos/alice/demo/check-runs/" + first_check.to_string(),
        first_token,
        Some({ "conclusion": "failure" }),
        verb=Patch,
      ).0,
      401,
    )
    assert_eq(
      @collaboration.require_merge_request(pool, scope, mr.number).title,
      "Updated via job",
    )
  })
}
