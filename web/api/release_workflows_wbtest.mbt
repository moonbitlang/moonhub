///|
async test "release and manual workflow choices coexist and the release run snapshots the tagged commit and credentials scope" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let dir = repo.git_dir(root)
    let workflow = ".github/workflows/build.yml"
    let source =
      #|name: Publish
      #|run-name: Release ${{ github.event.release.tag_name }}
      #|on:
      #|  release:
      #|    types: [released]
      #|  workflow_dispatch:
      #|jobs:
      #|  publish:
      #|    if: github.ref == 'refs/tags/v1.2.3' && github.event.action == 'released'
      #|    runs-on: [self-hosted, linux]
      #|    steps:
      #|      - id: publish
      #|        if: github.event_name == 'release'
      #|        env:
      #|          RELEASE_TAG: ${{ github.event.release.tag_name }}
      #|          CREDENTIALS: ${{ secrets.PUBLISH_TOKEN }}
      #|        run: test "$RELEASE_TAG" = v1.2.3
    let sha = @test_support.workflow_commit(dir, source)
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", sha]))
    // Mirror the MoonBack repository: the default symbolic ref points at an
    // unborn main, while the live release branch is master.
    ignore(@gitops.merge_git(dir, ["symbolic-ref", "HEAD", "refs/heads/main"]))
    let (page, html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/pipelines/new", cookie,
    )
    assert_eq(page.code, 200)
    assert_true(html.contains("name=\"branch\" value=\"master\""))
    assert_true(
      html.contains("<option value=\"" + workflow + "\" selected=\"\">Publish"),
    )
    assert_true(html.contains("All workflow jobs"))
    assert_false(html.contains("Unavailable workflows"))

    let scope = @repository.repository_scope(pool, actor, repo)
    @runtime.save_secret(
      pool,
      root,
      actor,
      scope,
      "PUBLISH_TOKEN",
      Some("fixture-credential"),
      "master",
      workflow,
      0L,
    )
    let write = @identity.create_access_token(
      pool, actor, "Release editor", "write", 1,
    )
    let execute = @identity.create_access_token(
      pool, actor, "Release executor", "execute", 1,
    )
    let route = "/repos/alice/demo/releases"
    let (created, draft) = api_test_request(
      port,
      route,
      write,
      Some({ "tag_name": "v1.2.3", "draft": true }),
    )
    assert_eq(created, 201)
    assert_true(
      draft is { "target_commitish": String(target), .. } && target == sha,
    )
    assert_false(@pipeline.run_next_ref_event(pool, root))
    let draft_id = match draft {
      { "id": id, .. } => id.stringify()
      _ => fail("expected a draft release ID")
    }
    let release_route = route + "/" + draft_id
    // The tag may already exist, and newer branch commits are not the release source.
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/tags/v1.2.3", sha]))
    ignore(@test_support.merge_test_commit(dir, "master", sha, "New tip"))
    for _ in 0..<2 {
      let (status, published) = api_test_request(
        port,
        release_route,
        execute,
        Some({ "draft": false }),
        verb=Patch,
      )
      assert_eq(status, 200)
      assert_true(published is { "draft": False, .. })
    }
    assert_false(@repository.pipeline_push_enabled(pool, actor, repo))
    assert_true(@pipeline.run_next_ref_event(pool, root))
    assert_false(@pipeline.run_next_ref_event(pool, root))
    let events = @runtime.list_trigger_events(pool, actor, repo)
    assert_eq(events.length(), 1)
    assert_eq(events[0].reference, "refs/tags/v1.2.3")
    assert_eq(events[0].error, "")
    assert_eq(events[0].runs.length(), 1)
    let run = events[0].runs[0]
    assert_eq(run.display_title, "Release v1.2.3")
    assert_eq(run.commit_sha, sha)
    assert_eq(run.source_branch, "master")
    assert_eq(run.workflow_source, source)
    assert_eq(run.context.unwrap().event_name, "release")
    assert_eq(run.context.unwrap().release_tag, Some("v1.2.3"))
    let (history, events_html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/pipelines?tab=events", cookie,
    )
    assert_eq(history.code, 200)
    assert_true(events_html.contains("<code>refs/tags/v1.2.3</code>"))
    assert_false(events_html.contains("View branch runs"))
    // Recover after a worker committed the run but had not finished the event.
    pool.with_client(c => {
      ignore(
        c.execute("UPDATE repository_ref_event SET state='ready'", params=[]),
      )
    })
    assert_true(@pipeline.run_next_ref_event(pool, root))
    assert_eq(@runtime.list_runs(pool, actor, repo).length(), 1)

    let c = @runtime.Coordinator::new(pool)
    c.cancel_run(actor, repo, run.number)
    let rerun = @pipeline.rerun_run(pool, root, actor, repo, run.number)
    assert_eq(rerun.commit_sha, sha)
    assert_eq(rerun.display_title, "Release v1.2.3")
    let provider = "c".repeat(64)
    let attempt = "d".repeat(64)
    let execution = "e".repeat(32)
    ignore(
      c.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "tagged-release",
        provider,
        ["self-hosted", "linux"],
        [repo],
      ),
    )
    let assignment = c
      .claim(provider, {
        environments: None,
        version: 1,
        request_id: "a".repeat(32),
        attempt_token: attempt,
        runner_os: None,
      })
      .unwrap()
    assert_eq(assignment.run_id, rerun.id.to_string())
    assert_eq(assignment.commit_sha, sha)
    assert_eq(assignment.job.context.get("ref"), Some("refs/tags/v1.2.3"))
    assert_eq(assignment.job.context.get("event_name"), Some("release"))
    assert_eq(
      assignment.job.event.get("action"),
      Some(Json::string("released")),
    )
    assert_true(
      assignment.job.event.get("release")
      is Some(
        {
          "tag_name": String("v1.2.3"),
          "target_commitish": String(pinned),
          "draft": False,
          "prerelease": False,
          ..
        },
      ) &&
      pinned == sha,
    )
    assert_false(
      ToJson::to_json(assignment).stringify().contains("fixture-credential"),
    )
    let id = number(assignment.attempt_id)
    ignore(c.start(id, attempt, 1, execution_id=execution))
    ignore(
      c.update_step(id, attempt, {
        version: 1,
        step_id: "publish",
        state: "running",
        exit_code: 0,
      }),
    )
    assert_eq(
      c.step_secrets(id, attempt, {
        version: 1,
        execution_id: execution,
        step_id: "publish",
      }).env.get("CREDENTIALS"),
      Some("fixture-credential"),
    )
  })
}

///|
async test "prereleases and untrusted release publishers do not create runs" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let dir = repo.git_dir(root)
    let off_branch = @test_support.workflow_commit(
      dir,
      @test_support.single_job_workflow.replace_all(
        old="on: workflow_dispatch",
        new="on: release",
      ),
    )
    let sha = @gitops.branch_sha(dir, "master")
    ignore(
      @gitops.merge_git(dir, ["update-ref", "refs/heads/main", off_branch]),
    )
    let execute = @identity.create_access_token(
      pool, actor, "Execute", "execute", 1,
    )
    let write = @identity.create_access_token(pool, actor, "Write", "write", 1)
    let member_token = @identity.create_access_token(
      pool, bob, "Member", "execute", 1,
    )
    pool.with_client(c => {
      ignore(
        c.execute(
          "INSERT INTO team_member(team_id,user_id,role) VALUES (1,2,'member')",
        ),
      )
    })
    let route = "/repos/alice/demo/releases"
    for
      (tag, target, prerelease, credential) in [
        ("v1.0.0-rc", sha, true, execute),
        ("v1.0.0", sha, false, write),
        ("v1.0.1", sha, false, member_token),
        ("v1.0.2", off_branch, false, execute),
      ] {
      assert_eq(
        api_test_request(
          port,
          route,
          credential,
          Some({
            "tag_name": tag,
            "target_commitish": target,
            "prerelease": prerelease,
          }),
        ).0,
        201,
      )
    }
    assert_false(@pipeline.run_next_ref_event(pool, root))
    let events = @runtime.list_trigger_events(pool, actor, repo)
    assert_eq(events.length(), 1)
    assert_eq(events[0].reference, "refs/tags/v1.0.2")
    assert_eq(events[0].error, "Release commit is not on the default branch.")
    assert_true(events[0].runs.is_empty())
    assert_eq(
      api_test_request(
        port,
        route,
        execute,
        Some({ "tag_name": "v1.0.3", "target_commitish": sha }),
      ).0,
      201,
    )
    pool.with_client(c => {
      ignore(
        c.execute(
          "UPDATE team_member SET role='member' WHERE team_id=1 AND user_id=1",
        ),
      )
    })
    assert_true(@pipeline.run_next_ref_event(pool, root))
    let revoked = @runtime.list_trigger_events(pool, actor, repo)[0]
    assert_eq(revoked.reference, "refs/tags/v1.0.3")
    assert_true(revoked.error.contains("repository owner or admin required"))
    assert_true(@runtime.list_runs(pool, actor, repo).is_empty())
  })
}
