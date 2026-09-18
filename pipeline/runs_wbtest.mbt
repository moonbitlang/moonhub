///|
let sample_workflow : String =
  #|name: Build
  #|on: workflow_dispatch
  #|jobs:
  #|  build:
  #|    runs-on: [self-hosted, linux]
  #|    steps:
  #|      - run: echo build
  #|  test:
  #|    runs-on: self-hosted
  #|    needs: build
  #|    steps:
  #|      - run: echo test

///|
async test "a run snapshots its configuration and pins source across force pushes and GC" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let alice = @identity.active_user_by_name(pool, "alice")
    let sha = @test_support.workflow_commit(git_dir, sample_workflow)
    let run = create_run(
      pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
    )
    try
      ignore(
        get_run(pool, alice, { owner: "alice", name: "public", }, run.number),
      )
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("a run crossed repository scope")
    }
    assert_eq(run.number, 1L)
    assert_eq(run.commit_sha, sha)
    assert_eq(run.workflow_source, sample_workflow)
    assert_eq(run.state, Queued)
    assert_eq(run.conclusion, None)
    assert_eq(run.definition_version, @workflow.format_version)
    assert_eq(run.definition.jobs.length(), 2)
    assert_eq(
      @gitops.merge_git(git_dir, ["rev-parse", run.source_ref]).trim(),
      sha,
    )
    let jobs = list_jobs(pool, alice, repo, run.number)
    assert_eq(jobs.length(), 2)
    assert_eq(
      jobs.iter().find_first(job => job.job_key == "build").unwrap().state,
      Queued,
    )
    assert_eq(
      jobs.iter().find_first(job => job.job_key == "test").unwrap().state,
      Waiting,
    )
    pool.with_client(client => {
      assert_eq(client.query_all("SELECT * FROM pipeline_job_need").length(), 1)
      assert_eq(
        client.query_all("SELECT * FROM pipeline_job_attempt").length(),
        0,
      )
    })
    let next_sha = @test_support.workflow_commit(
      git_dir,
      sample_workflow.replace_all(old="echo build", new="echo changed"),
    )
    assert_true(next_sha != sha)
    ignore(
      @gitops.merge_git(git_dir, ["reflog", "expire", "--expire=now", "--all"]),
    )
    ignore(@gitops.merge_git(git_dir, ["gc", "--prune=now"]))
    assert_eq(
      @gitops.merge_git(git_dir, ["cat-file", "-t", sha]).trim(),
      "commit",
    )
    let restored = get_run(pool, alice, repo, 1L)
    assert_eq(restored.commit_sha, sha)
    assert_eq(restored.workflow_source, sample_workflow)
    assert_eq(
      ToJson::to_json(restored.definition),
      ToJson::to_json(run.definition),
    )
    let second = create_run(
      pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
    )
    assert_eq(second.number, 2L)
    assert_eq(second.commit_sha, next_sha)
    assert_true(second.source_ref != run.source_ref)
  })
}

///|
async test "explicit rerun clones the completed snapshot instead of the current branch" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let alice = @identity.active_user_by_name(pool, "alice")
    let sha = @test_support.workflow_commit(git_dir, sample_workflow)
    let original = create_run(
      pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_job SET status = 'completed', conclusion = 'success' WHERE run_id = ?",
          params=[original.id],
        ),
      )
      ignore(
        client.execute(
          "UPDATE pipeline_run SET status = 'completed', conclusion = 'success' WHERE id = ?",
          params=[original.id],
        ),
      )
    })
    let rerun = rerun_run(pool, root, alice, repo, original.number)
    assert_eq(rerun.number, 2L)
    assert_eq(rerun.commit_sha, sha)
    assert_eq(rerun.workflow_source, original.workflow_source)
    assert_eq(
      ToJson::to_json(rerun.definition),
      ToJson::to_json(original.definition),
    )
    assert_true(rerun.source_ref != original.source_ref)
    assert_eq(rerun.state, Queued)
    assert_true(
      list_jobs(pool, alice, repo, rerun.number)
      .iter()
      .find_first(job => job.job_key == "build")
      .unwrap().state
      is Queued,
    )
    assert_true(
      @gitops.merge_git(git_dir, ["rev-parse", rerun.source_ref]).trim() == sha,
    )
  })
}

///|
async test "active pipeline runs cannot be implicitly rerun" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    ignore(@test_support.workflow_commit(repo.git_dir(root), sample_workflow))
    let alice = @identity.active_user_by_name(pool, "alice")
    let run = create_run(
      pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
    )
    try ignore(rerun_run(pool, root, alice, repo, run.number)) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("reran an active pipeline")
    }
  })
}

///|
async test "pipeline creation and reads enforce current repository permissions" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let admin = @identity.active_user_by_name(pool, "admin")
    ignore(@test_support.workflow_commit(repo.git_dir(root), sample_workflow))
    let run = create_run(
      pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
    )
    try ignore(get_run(pool, bob, repo, run.number)) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("another user read a private run")
    }
    try
      ignore(
        create_run(
          pool, root, bob, repo, "pipeline", ".github/workflows/build.yml",
        ),
      )
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("another user created a private run")
    }
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
      )
    })
    assert_eq(get_run(pool, bob, repo, run.number).id, run.id)
    try
      ignore(
        create_run(
          pool, root, bob, repo, "pipeline", ".github/workflows/build.yml",
        ),
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("a non-manager created a run")
    }
    assert_eq(
      create_run(
        pool, root, admin, repo, "pipeline", ".github/workflows/build.yml",
      ).number,
      2L,
    )
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET is_site_admin = 0 WHERE id = 3",
      )
    })
    try
      ignore(
        create_run(
          pool, root, admin, repo, "pipeline", ".github/workflows/build.yml",
        ),
      )
    catch {
      @domain.NotFound(_) | @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale admin identity bypassed permission checks")
    }
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE \"user\" SET status = 'disabled' WHERE id = 1",
      )
    })
    try ignore(get_run(pool, alice, repo, run.number)) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("disabled account read a run")
    }
    assert_eq(
      pool.with_client(client => {
        client.query_all("SELECT id FROM pipeline_run").length()
      }),
      2,
    )
  })
}

///|
async test "invalid source paths workflows and symlinks leave no runs or pins" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let alice = @identity.active_user_by_name(pool, "alice")
    let git_dir = repo.git_dir(root)
    ignore(@test_support.workflow_commit(git_dir, sample_workflow))
    for
      path in [
        "../build.yml", ".github/workflows/../../config", ".github/workflows/nested/build.yml",
        ".github/workflows/missing.yml", ".github/workflows/build.yml:other",
      ] {
      try ignore(create_run(pool, root, alice, repo, "pipeline", path)) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted path: \{path}")
      }
    }
    for
      branch in [
        "missing", "pipeline^{commit}", "--all", "refs/moonhub/pipelines/hidden",
      ] {
      try
        ignore(
          create_run(
            pool, root, alice, repo, branch, ".github/workflows/build.yml",
          ),
        )
      catch {
        @gitops.Failure(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted branch expression")
      }
    }
    for
      source in [
        sample_workflow + "\npermissions: write-all",
        "not a workflow",
        "#" + "x".repeat(@workflow.max_source_bytes),
      ] {
      ignore(@test_support.workflow_commit(git_dir, source))
      try
        ignore(
          create_run(
            pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
          ),
        )
      catch {
        @domain.BadRequest(_) | @gitops.Failure(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid workflow")
      }
    }
    ignore(
      @test_support.workflow_commit(git_dir, "../../private", mode="120000"),
    )
    try
      ignore(
        create_run(
          pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
        ),
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted symlink workflow")
    }
    assert_eq(
      pool.with_client(client => {
        client.query_all("SELECT id FROM pipeline_run").length()
      }),
      0,
    )
    assert_eq(
      @gitops.merge_git(git_dir, [
        "for-each-ref", "--format=%(refname)", "refs/moonhub/pipelines/",
      ]),
      "",
    )
  })
}

///|
async test "database failures roll back the entire snapshot and release its Git pin" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let alice = @identity.active_user_by_name(pool, "alice")
    let git_dir = repo.git_dir(root)
    ignore(@test_support.workflow_commit(git_dir, sample_workflow))
    pool.with_client(client => {
      client.batch_execute(
        "CREATE TRIGGER reject_pipeline_job BEFORE INSERT ON pipeline_job BEGIN SELECT RAISE(ABORT, 'injected failure'); END;",
      )
    })
    let failed = try {
      ignore(
        create_run(
          pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
        ),
      )
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    assert_eq(
      pool.with_client(client => {
        client.query_all("SELECT id FROM pipeline_run").length()
      }),
      0,
    )
    assert_eq(
      pool.with_client(client => {
        client.query_all("SELECT id FROM pipeline_job").length()
      }),
      0,
    )
    assert_eq(
      @gitops.merge_git(git_dir, [
        "for-each-ref", "--format=%(refname)", "refs/moonhub/pipelines/",
      ]),
      "",
    )
    pool.with_client(client => {
      client.batch_execute("DROP TRIGGER reject_pipeline_job")
    })
    assert_eq(
      create_run(
        pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
      ).number,
      1L,
    )
  })
}

///|
async test "concurrent requests allocate distinct run numbers and immutable snapshots" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let alice = @identity.active_user_by_name(pool, "alice")
    ignore(@test_support.workflow_commit(repo.git_dir(root), sample_workflow))
    @async.with_task_group(group => {
      let first = group.spawn(() => {
        create_run(
          pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
        )
      })
      let second = group.spawn(() => {
        create_run(
          pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
        )
      })
      let first = first.wait()
      let second = second.wait()
      assert_true(first.number != second.number)
      assert_eq(first.commit_sha, second.commit_sha)
    })
    let rejected = pool.with_client(client => {
      let _ = client.execute(
        "UPDATE pipeline_run SET workflow_source = 'changed' WHERE number = 1",
      )
      false
    }) catch {
      _ => true
    }
    assert_true(rejected)
    assert_eq(get_run(pool, alice, repo, 1L).workflow_source, sample_workflow)
    assert_true(
      pool.with_client(client => {
        client.query_all("PRAGMA foreign_key_check").is_empty()
      }),
    )
  })
}

///|
async test "pipeline snapshots survive closing and reopening the database" {
  @test_support.with_git_test_repo((root, git_dir) => {
    @async.with_task_group(group => {
      let config : @database.DbConfig = { path: "\{root}/pipeline.db", }
      let pool = @database.new_db_pool(config, group)
      let mut original_open = true
      defer (if original_open { pool.close() })
      @database.initialize_db(pool)
      pool.with_client(client => {
        client.batch_execute(
          "INSERT INTO \"user\" (id, name_key, display_name, password_hash) VALUES (1, 'alice', 'Alice', 'test');\n" +
          "INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'alice', 'Alice', 'personal');\n" +
          "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 1, 'owner');\n" +
          "INSERT INTO repository (id, team_id, name, visibility) VALUES (1, 1, 'demo', 'private');",
        )
      })
      let actor = @identity.active_user_by_name(pool, "alice")
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      ignore(@test_support.workflow_commit(git_dir, sample_workflow))
      let run = create_run(
        pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
      )
      pool.close()
      original_open = false
      let reopened = @database.new_db_pool(config, group)
      defer reopened.close()
      @database.initialize_db(reopened)
      let restored = get_run(reopened, actor, repo, run.number)
      assert_eq(restored.commit_sha, run.commit_sha)
      assert_eq(restored.source_ref, run.source_ref)
      assert_eq(restored.state, Queued)
      assert_eq(restored.workflow_source, sample_workflow)
      assert_eq(list_jobs(reopened, actor, repo, run.number).length(), 2)
    })
  })
}

///|
async test "attempt history and same-run dependency constraints are enforced" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let alice = @identity.active_user_by_name(pool, "alice")
    ignore(@test_support.workflow_commit(repo.git_dir(root), sample_workflow))
    let run = create_run(
      pool, root, alice, repo, "pipeline", ".github/workflows/build.yml",
    )
    let job = list_jobs(pool, alice, repo, run.number)[0]
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO pipeline_job_attempt (job_id, number, status) VALUES (?, 1, 'leased')",
        params=[job.id],
      )
      let rejected = try {
        let _ = client.execute(
          "INSERT INTO pipeline_job_attempt (job_id, number, status) VALUES (?, 2, 'leased')",
          params=[job.id],
        )
        false
      } catch {
        _ => true
      }
      assert_true(rejected)
      let _ = client.execute(
        "UPDATE pipeline_job_attempt SET status = 'completed', conclusion = 'lost', finished_at = datetime('now') WHERE job_id = ?",
        params=[job.id],
      )
      let _ = client.execute(
        "INSERT INTO pipeline_job_attempt (job_id, number, status) VALUES (?, 2, 'leased')",
        params=[job.id],
      )
      assert_eq(
        client
        .query_all("SELECT id FROM pipeline_job_attempt WHERE job_id = ?", params=[
          job.id,
        ])
        .length(),
        2,
      )
      for
        sql in [
          "UPDATE pipeline_run SET status = 'completed' WHERE number = 1", "UPDATE pipeline_job SET conclusion = 'success' WHERE status = 'queued'",
          "INSERT INTO pipeline_job_need (run_id, job_key, needs_job_key) VALUES (999, 'build', 'test')",
        ] {
        let rejected = try {
          ignore(client.execute(sql))
          false
        } catch {
          _ => true
        }
        assert_true(rejected, msg=sql)
      }
    })
    assert_eq(get_run(pool, alice, repo, run.number).state, Queued)
  })
}
