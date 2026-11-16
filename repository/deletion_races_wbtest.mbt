///|
async test "repository control handles remain exclusive across deletion cleanup and same-name rebuild" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let old = repository_write_lock(root, repo)
    defer old.close()
    old.unlock()
    delete_repository(pool, root, actor, repo, 1L, repo.path())
    cleanup_deleted_repositories(pool, root)
    create_managed_repository(pool, root, repo, "private", false)
    let current = repository_write_lock(root, repo)
    defer current.close()
    assert_false(old.try_lock(Exclusive))
    current.unlock()
    assert_true(old.try_lock(Exclusive))
    assert_false(current.try_lock(Exclusive))
    assert_true(repository_scope(pool, actor, repo).id != 1L)
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
    assert_false(@fs.exists("\{root}/.mirrors/\{id}"))
    let selected = @async.Semaphore(1, initial_value=0)
    @async.with_task_group(group => {
      let worker = group.spawn(() => {
        selected.release()
        sync_next_mirror(pool, root, config)
      })
      selected.acquire()
      delete_repository(pool, root, actor, repo, 1L, repo.path())
      lock.unlock()
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
    assert_false(lock.try_lock(Exclusive))
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
