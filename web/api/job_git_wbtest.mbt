///|
async test "job Git smart HTTP pushes obey protected refs live scope and nonrecursive events on both mounts" {
  let binary = @fs.realpath("_build/native/debug/build/moonhub.exe")
  @web_testkit.with_repository_test_app(
    (port, pool, root, _, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let workflow = @test_support.single_job_workflow +
        "\npermissions: {contents: write}"
      let sha = @test_support.workflow_commit(repo.git_dir(root), workflow)
      ignore(
        @pipeline.create_run(
          pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
        ),
      )
      let c = @runtime.Coordinator::new(pool)
      ignore(
        c.create_provider(
          @identity.active_user_by_name(pool, "admin"),
          "job-git",
          "c".repeat(64),
          ["self-hosted", "linux"],
          [repo],
        ),
      )
      let assignment = c
        .claim("c".repeat(64), {
          environments: None,
          runner_os: None,
          version: 1,
          request_id: "a".repeat(32),
          attempt_token: "d".repeat(64),
        })
        .unwrap()
      let id = number(assignment.attempt_id)
      ignore(c.start(id, "d".repeat(64), 1, execution_id="e".repeat(32)))
      let grant = c.api_runtime(id, "d".repeat(64), {
        version: 1,
        execution_id: "e".repeat(32),
      })
      @repository.set_pipeline_push_enabled(pool, root, actor, repo, true)
      @collaboration.save_branch_rule(
        pool,
        @repository.repository_scope(pool, actor, repo),
        repo.git_dir(root),
        actor,
        "master",
        true,
        0L,
      )
      for prefix in ["/-/api/v1", "/api/v3"] {
        @async.with_task_group(group => {
          let (stdin, writer) = @process.write_to_process()
          defer writer.close()
          group.spawn_bg(() => {
            writer.write(
              (
                {
                  "port": port,
                  "prefix": prefix,
                  "token": grant.token,
                  "source": repo.git_dir(root),
                  "sha": sha,
                } : Json).stringify(),
            )
            writer.close()
          })
          let (code, stdout, stderr) = @process.collect_output(
            "node",
            ["scripts/job-git-smoke.mjs"],
            stdin~,
          )
          assert_eq(code, 0, msg=stderr.text())
          assert_true(stdout.text().contains("JOB_GIT_PUSH_AND_POLICY_OK"))
        })
      }
      pool.with_client(client => {
        assert_eq(
          (
            client
            .query_one("SELECT count(*) n FROM repository_ref_event")
            .get_name("n") : Int64),
          0L,
        )
        assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
      })
      for state in ["running", "success"] {
        ignore(
          c.update_step(id, "d".repeat(64), {
            version: 1,
            step_id: "check",
            state,
            exit_code: 0,
          }),
        )
      }
      ignore(
        c.complete(id, "d".repeat(64), {
          version: 1,
          conclusion: "success",
          last_log_sequence: "0",
          outputs: Map([]),
        }),
      )
      @async.with_task_group(group => {
        let (stdin, writer) = @process.write_to_process()
        defer writer.close()
        group.spawn_bg(() => {
          writer.write(
            (
              {
                "port": port,
                "prefix": "/-/api/v1",
                "token": grant.token,
                "source": repo.git_dir(root),
                "sha": sha,
                "denied": true,
              } : Json).stringify(),
          )
          writer.close()
        })
        let (code, _, stderr) = @process.collect_output(
          "node",
          ["scripts/job-git-smoke.mjs"],
          stdin~,
        )
        assert_eq(code, 0, msg=stderr.text())
      })
      let read_workflow = @test_support.single_job_workflow +
        "\npermissions: {contents: read}"
      ignore(@test_support.workflow_commit(repo.git_dir(root), read_workflow))
      ignore(
        @pipeline.create_run(
          pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
        ),
      )
      let read_assignment = c
        .claim("c".repeat(64), {
          environments: None,
          runner_os: None,
          version: 1,
          request_id: "b".repeat(32),
          attempt_token: "f".repeat(64),
        })
        .unwrap()
      let read_id = number(read_assignment.attempt_id)
      ignore(c.start(read_id, "f".repeat(64), 1, execution_id="f".repeat(32)))
      let read_grant = c.api_runtime(read_id, "f".repeat(64), {
        version: 1,
        execution_id: "f".repeat(32),
      })
      assert_eq(
        api_test_request(
          port,
          "/repos/alice/demo/git/info/refs?service=git-receive-pack",
          read_grant.token,
          None,
        ).0,
        403,
      )
    },
    persistent_db=true,
    job_git_binary=binary,
  )
}
