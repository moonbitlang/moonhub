///|
async test "secret policy diagnostics do not suppress other push workflows" {
  for policy in ["missing", "branch", "workflow"] {
    @test_support.with_repository_test_data((pool, root) => {
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let actor = @identity.active_user_by_name(pool, "alice")
      let dir = repo.git_dir(root)
      let denied = @test_support.single_job_workflow
        .replace_all(old="on: workflow_dispatch", new="on: push")
        .replace_all(
          old="run: echo fixture",
          new="env: {TOKEN: '${{ secrets.TOKEN }}'}\n        run: 'true'",
        )
      // Ensure the test reaches secret policy validation, not YAML rejection.
      assert_eq(
        @workflow.parse(denied).jobs[0].steps[0].secret_env.get("TOKEN"),
        Some("TOKEN"),
      )
      let valid = @test_support.single_job_workflow.replace_all(
        old="on: workflow_dispatch",
        new="on: push",
      )
      let denied_blob = @gitops.merge_git(
          dir,
          ["hash-object", "-w", "--stdin"],
          input=denied,
        )
        .trim()
        .to_owned()
      let valid_blob = @gitops.merge_git(
          dir,
          ["hash-object", "-w", "--stdin"],
          input=valid,
        )
        .trim()
        .to_owned()
      let workflows = @gitops.merge_git(
          dir,
          ["mktree"],
          input="100644 blob \{denied_blob}\ta-publish.yml\n100644 blob \{valid_blob}\tb-build.yml\n",
        )
        .trim()
        .to_owned()
      let github = @gitops.merge_git(
          dir,
          ["mktree"],
          input="040000 tree \{workflows}\tworkflows\n",
        )
        .trim()
        .to_owned()
      let tree = @gitops.merge_git(
          dir,
          ["mktree"],
          input="040000 tree \{github}\t.github\n",
        )
        .trim()
        .to_owned()
      let sha = @gitops.merge_git(dir, [
          "commit-tree", tree, "-m", "Secret policy fixture",
        ])
        .trim()
        .to_owned()
      ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/review", sha]))
      if policy != "missing" {
        ignore(
          @gitops.merge_git(dir, ["update-ref", "refs/heads/publish", sha]),
        )
        save_secret(
          pool,
          root,
          actor,
          repo,
          "TOKEN",
          Some("private-push-token"),
          if policy == "branch" {
            "publish"
          } else {
            "review"
          },
          if policy == "workflow" {
            ".github/workflows/other.yml"
          } else {
            ".github/workflows/a-publish.yml"
          },
          0L,
        )
      }
      @repository.set_pipeline_push_enabled(pool, root, actor, repo, true)
      @repository.record_received_transaction(
        pool,
        actor,
        repo,
        "e".repeat(32),
        "prepared",
        "\{"0".repeat(40)} \{sha} refs/heads/review",
      )
      assert_true(run_next_push_event(pool, root))
      let events = list_trigger_events(pool, actor, repo)
      assert_eq(events[0].state, "processed")
      assert_true(events[0].error.contains(".github/workflows/a-publish.yml"))
      assert_true(events[0].error.contains("Secret TOKEN"))
      assert_true(!events[0].error.contains("private-push-token"))
      let runs = list_runs(pool, actor, repo)
      assert_eq(runs.length(), 1)
      assert_eq(runs[0].workflow_path, ".github/workflows/b-build.yml")
      assert_eq(events[0].runs.length(), 1)
      assert_false(run_next_push_event(pool, root))
    })
  }
}

///|
async test "MR secret policy reports configuration errors without claiming execution access was revoked" {
  with_merge_check_fixture(
    (pool, root, _, actor, mr) => {
      poll_merge_checks(pool, root)
      let checks = @collaboration.merge_checks(pool, mr)
      assert_eq(checks.length(), 1)
      assert_eq(checks[0].state, "error")
      assert_true(checks[0].error.contains("never MR checks"))
      assert_true(!checks[0].error.contains("permission was revoked"))
      assert_true(list_runs(pool, actor, protocol_repo).is_empty())
    },
    workflow=pull_request_workflow.replace_all(
      old="run: test -f README.md",
      new="env: {TOKEN: '${{ secrets.TOKEN }}'}\n        run: 'true'",
    ),
  )
}
