///|
async test "repository control handles remain exclusive across deletion cleanup and same-name rebuild" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let old = repository_write_lock(root, repo)
    defer old.close()
    let retained = @fs.open(repository_lock_path(root, repo), mode=ReadWrite)
    defer retained.close()
    old.close()
    delete_repository(pool, root, actor, repo, 1L, repo.path())
    cleanup_deleted_repositories(pool, root)
    create_managed_repository(pool, root, repo, "private", false)
    let current = repository_write_lock(root, repo)
    defer current.close()
    assert_false(retained.try_lock(Exclusive))
    current.close()
    assert_true(retained.try_lock(Exclusive))
    assert_true(@gitops.try_file_lock(repository_lock_path(root, repo)) is None)
    assert_true(repository_scope(pool, actor, repo).id != 1L)
  })
}

///|
async test "a waiting writer rejects a replacement identity and leaves its refs and files intact" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = repository_scope(pool, actor, repo)
    let lock = repository_write_lock(root, repo)
    defer lock.close()
    let started = @async.Semaphore(1, initial_value=0)
    @async.with_task_group(group => {
      let writer = group.spawn(() => {
        started.release()
        try
          with_repository_write(pool, root, actor, scope, (_, dir) => {
            @fs.write_file("\{dir}/corrupt", "stale request")
            ignore(
              @gitops.merge_git(dir, ["update-ref", "-d", "refs/heads/master"]),
            )
          })
        catch {
          @domain.BadRequest(message~) =>
            assert_true(message.contains("has changed"))
          err => raise err
        } noraise {
          _ => fail("stale writer entered the replacement repository")
        }
      })
      started.acquire()
      // Act as deletion and publication while owning their common control lock.
      // The old request has captured its scope and is waiting for this lock.
      pool.with_client(client => {
        client.with_transaction(
          tx => {
            ignore(
              tx.execute("DELETE FROM repository WHERE id=?", params=[scope.id]),
            )
            ignore(
              tx.execute(
                "INSERT INTO repository(team_id,name) VALUES(1,'demo')",
              ),
            )
          },
          immediate=true,
        )
      })
      @fs.rename(repo.git_dir(root), "\{root}/retired.git")
      let (code, output) = @process.collect_output_merged("git", [
        "clone",
        "--bare",
        "--no-hardlinks",
        "\{root}/retired.git",
        repo.git_dir(root),
      ])
      assert_eq(code, 0, msg=output.text())
      @fs.write_file("\{repo.git_dir(root)}/keep", "replacement")
      let refs = @gitops.run_git(repo.git_dir(root), ["show-ref"])
      lock.close()
      writer.wait()
      assert_eq(@gitops.run_git(repo.git_dir(root), ["show-ref"]), refs)
      assert_eq(
        @fs.read_file("\{repo.git_dir(root)}/keep").text(),
        "replacement",
      )
      assert_false(@fs.exists("\{repo.git_dir(root)}/corrupt"))
    })
  })
}

///|
async test "mirror candidate selected before deletion cannot claim or recreate a working directory" {
  mirror_fixture((pool, root, actor, repo, config, _) => {
    let id = save_fixture_mirror(
      pool,
      root,
      actor,
      repo,
      0L,
      0L,
      "git@destination.example:repo.git",
      true,
      false,
      false,
      host_keys=@test_support.test_ssh_public_key,
    )
    let lock = mirror_lock(root, id)
    defer lock.close()
    let retained = @fs.open(mirror_lock_path(root, id), mode=ReadWrite)
    defer retained.close()
    assert_false(@fs.exists("\{root}/.mirrors/\{id}"))
    let selected = @async.Semaphore(1, initial_value=0)
    @async.with_task_group(group => {
      let worker = group.spawn(() => {
        selected.release()
        sync_next_mirror(pool, root, config)
      })
      selected.acquire()
      delete_repository(pool, root, actor, repo, 1L, repo.path())
      lock.close()
      assert_true(worker.wait())
    })
    assert_false(@fs.exists("\{root}/.mirrors/\{id}"))
    assert_true(claim_mirror(pool, id) is None)
    pool.with_client(client => {
      assert_true(client.query_all("SELECT * FROM mirror_attempt").is_empty())
    })
    cleanup_deleted_repositories(pool, root)
    let current = mirror_lock(root, id)
    defer current.close()
    assert_false(retained.try_lock(Exclusive))
  })
}

///|
async test "mirror claim committed first blocks deletion and deletion committed first blocks claim" {
  mirror_fixture((pool, root, actor, repo, _, _) => {
    let id = save_fixture_mirror(
      pool,
      root,
      actor,
      repo,
      0L,
      0L,
      "git@destination.example:repo.git",
      true,
      false,
      false,
      host_keys=@test_support.test_ssh_public_key,
    )
    let lock = mirror_lock(root, id)
    defer lock.close()
    assert_true(claim_mirror(pool, id) is Some(_))
    try delete_repository(pool, root, actor, repo, 1L, repo.path()) catch {
      @domain.BadRequest(message~) =>
        assert_true(message.contains("mirror is syncing"))
      err => raise err
    } noraise {
      _ => fail("deleted a repository with a claimed mirror")
    }
    assert_true(can_access_repository(pool, actor, repo, Write))
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE repository_mirror SET status='failed' WHERE id=?",
          params=[id],
        ),
      )
    })
    delete_repository(pool, root, actor, repo, 1L, repo.path())
    assert_true(claim_mirror(pool, id) is None)
    assert_false(@fs.exists("\{root}/.mirrors/\{id}"))
  })
}

///|
async test "control paths reject symlinks directories and dangling lock symlinks" {
  @test_support.with_repository_test_data((_, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    @fs.mkdir("\{root}/elsewhere")
    @fs.symlink(target="\{root}/elsewhere", "\{root}/.locks")
    try ignore(repository_write_lock(root, repo)) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("followed a control directory symlink")
    }
    @fs.remove("\{root}/.locks")
    let path = control_lock_path(
      root,
      "repositories",
      @identity.hash_token(repo.path()),
    )
    for directory in [false, true] {
      if directory {
        @fs.mkdir(path)
      } else {
        @fs.symlink(target="\{root}/missing", path)
      }
      try ignore(repository_write_lock(root, repo)) catch {
        @gitops.Failure(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted an invalid control file")
      }
      if directory {
        @fs.rmdir(path)
      } else {
        @fs.remove(path)
      }
    }
  })
}

///|
async test "import publication rejects a replaced staging token without marking the new claim failed" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
    let repo = enqueue_repository(
      pool, root, actor, team, "staged", "private", "",
    )
    let lock = repository_write_lock(root, repo)
    defer lock.close()
    @async.with_task_group(group => {
      let worker = group.spawn(() => run_next_repository_job(pool, root, None))
      let job = @async.with_timeout(10000, () => {
        for ;; {
          let job = require_repository_job(pool, team, repo.name)
          if job.status == "running" &&
            !job.stage_token.is_empty() &&
            @fs.exists(
              "\{root}/.imports/\{job.id}-\{job.stage_token}.git/moonhub-provisioned",
            ) {
            break job
          }
          @async.pause()
        }
      })
      let replacement = "f".repeat(32)
      assert_true(job.stage_token != replacement)
      pool.with_client(client => {
        ignore(
          client.execute(
            "UPDATE repository_job SET stage_token=? WHERE repository_id=?",
            params=[replacement, job.id],
          ),
        )
      })
      lock.close()
      assert_true(worker.wait())
      let current = require_repository_job(pool, team, repo.name)
      assert_eq(current.stage_token, replacement)
      assert_eq(current.status, "running")
      assert_false(@fs.exists(repo.git_dir(root)))
      assert_false(can_access_repository(pool, actor, repo, Read))
    })
  })
}

///|
async test "scope validation distinguishes absence from changed team or normalized name" {
  @test_support.with_repository_test_data((pool, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = repository_scope(pool, actor, repo)
    require_current_scope(pool, scope)
    for
      expected in [
        { ..scope, team_id: 2L, },
        { ..scope, repo: { owner: "alice", name: "renamed", }, },
      ] {
      try require_current_scope(pool, expected) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted a changed repository identity")
      }
    }
    pool.with_client(client => {
      ignore(
        client.execute("DELETE FROM repository WHERE id=?", params=[scope.id]),
      )
    })
    try require_current_scope(pool, scope) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted a deleted repository")
    }
    try ignore(repository_scope(pool, actor, repo)) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("resolved a deleted repository")
    }
  })
}
