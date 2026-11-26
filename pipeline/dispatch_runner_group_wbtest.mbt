///|
async test "manual runner group restricts selected jobs dependencies and reruns" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo = protocol_repo
    let dir = repo.git_dir(root)
    let actor = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let c = test_services(pool)
    let source = dag_workflow
      .replace_all(
        old="runs-on: [self-hosted, linux]",
        new="runs-on: self-hosted",
      )
      .replace_all(
        old="    needs: build\n    runs-on: self-hosted",
        new="    needs: build\n    runs-on: {group: trusted, labels: [self-hosted, linux]}",
      )
    let sha = @test_support.workflow_commit(dir, source)
    let linux_secret = "c".repeat(64)
    let windows_secret = "d".repeat(64)
    let linux = c.runtime.create_provider(
      admin,
      "trusted-linux",
      linux_secret,
      ["self-hosted", "linux"],
      [repo],
    )
    let windows = c.runtime.create_provider(
      admin,
      "trusted-windows",
      windows_secret,
      ["self-hosted", "windows"],
      [repo],
    )
    ignore(
      c.runtime.create_provider(
        admin,
        "generic-linux",
        provider_secret,
        ["self-hosted", "linux"],
        [repo],
      ),
    )
    c.runtime.save_runner_group(admin, "trusted", 0L, [linux.id, windows.id], [
      repo,
    ])
    let run = create_run(
      pool,
      root,
      actor,
      repo,
      "pipeline",
      ".github/workflows/build.yml",
      jobs=["test"],
      runner_group=Some("Trusted"),
    )
    assert_eq(run.workflow_source, source)
    assert_eq(run.commit_sha, sha)
    assert_eq(run.definition.jobs.map(job => job.id), ["build", "test"])
    assert_eq(run.definition.jobs.map(job => job.runner_group), [
      "trusted", "trusted",
    ])
    assert_eq(run.definition.jobs[0].runs_on, ["self-hosted", "linux"])
    assert_true(c.runtime.claim(provider_secret, claim_request()) is None)
    assert_true(
      c.runtime.claim(windows_secret, {
        ..claim_request(),
        runner_os: Some("windows"),
      })
      is None,
    )
    let build = c.runtime.claim(linux_secret, claim_request()).unwrap()
    assert_eq(build.job.id, "build")
    ignore(complete_output_job(c, build, attempt_secret, Map([])))
    assert_true(
      c.runtime.claim(
        provider_secret,
        claim_request(id="2", secret="9".repeat(64)),
      )
      is None,
    )
    let test_job = c.runtime
      .claim(linux_secret, claim_request(id="2", secret="e".repeat(64)))
      .unwrap()
    assert_eq(test_job.job.id, "test")
    ignore(complete_output_job(c, test_job, "e".repeat(64), Map([])))
    let rerun = rerun_run(pool, root, actor, repo, run.number)
    assert_eq(rerun.workflow_source, source)
    assert_eq(rerun.commit_sha, sha)
    assert_eq(rerun.definition.jobs.map(job => job.runner_group), [
      "trusted", "trusted",
    ])
    assert_true(
      c.runtime.claim(
        provider_secret,
        claim_request(id="3", secret="9".repeat(64)),
      )
      is None,
    )
    assert_eq(
      c.runtime
      .claim(linux_secret, claim_request(id="3", secret="f".repeat(64)))
      .unwrap().job.id,
      "build",
    )
  })
}

///|
async test "manual runner group rejects conflicts dynamic matrices and reusable calls atomically" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo = protocol_repo
    let dir = repo.git_dir(root)
    let actor = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let c = test_services(pool)
    c.runtime.save_runner_group(admin, "trusted", 0L, [], [repo])
    let path = ".github/workflows/build.yml"
    let conflicting = @test_support.single_job_workflow.replace_all(
      old="[self-hosted, linux]",
      new="{group: different, labels: [self-hosted, linux]}",
    )
    ignore(
      filter_test_commit(dir, @gitops.branch_sha(dir, "master"), "pipeline", [
        (path, conflicting),
        (".github/workflows/dynamic.yml", dynamic_schedule_workflow),
        (".github/workflows/reusable.yml", call_workflow),
        (".github/workflows/callee.yml", called_workflow),
      ]),
    )
    for
      (name, job, error) in [
        (path, "build", "already selects runner group different"),
        (
          ".github/workflows/dynamic.yml", "after", "does not support dynamic matrices",
        ),
        (
          ".github/workflows/reusable.yml", "after", "does not support dynamic matrices",
        ),
      ] {
      try
        create_run(
          pool,
          root,
          actor,
          repo,
          "pipeline",
          name,
          jobs=[job],
          runner_group=Some("trusted"),
        )
      catch {
        @domain.BadRequest(message~) =>
          assert_true(message.contains(error), msg=message)
        err => raise err
      } noraise {
        _ => fail("invalid dispatch was accepted")
      }
    }
    let pins = @gitops.merge_git(dir, [
      "for-each-ref", "refs/moonhub/pipelines/",
    ])
    assert_eq(pins, "")
    let run = create_run(pool, root, actor, repo, "pipeline", path)
    assert_eq(run.number, 1L)
    assert_eq(run.definition.jobs[0].runner_group, "different")
  })
}
