///|
async test "shared repository admission excludes writers until admission closes" {
  @test_support.with_repository_test_data((_, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let first = repository_read_lock(root, repo)
    defer first.close()
    let second = repository_read_lock(root, repo)
    defer second.close()
    let path = control_lock_path(
      root,
      "repositories",
      @identity.hash_token(repo.path()),
    )
    assert_true(@gitops.try_file_lock(path) is None)
    first.close()
    assert_true(@gitops.try_file_lock(path) is None)
    second.close()
    guard @gitops.try_file_lock(path) is Some(writer) else {
      fail("writer remained blocked after repository admission closed")
    }
    defer writer.close()
    writer.close()
    let current = repository_write_lock(root, repo)
    defer current.close()
    assert_true(@gitops.try_file_lock(path, mode=Shared) is None)
  })
}

///|
async test "reader lifetimes permit writes and logical deletion but retain data and name reservation" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let actor = @identity.active_user_by_name(pool, "alice")
    let admission = repository_read_lock(root, repo)
    defer admission.close()
    let first = repository_reader_lock(root, 1L)
    defer first.close()
    let second = repository_reader_lock(root, 1L)
    defer second.close()
    admission.close()
    let writer = repository_write_lock(root, repo)
    writer.close()
    change_repository_visibility(
      pool, root, actor, repo, 1L, "private", "public",
    )
    delete_repository(pool, root, actor, repo, 1L, repo.path())
    // A busy name control lock and a busy reader lock both defer without failure.
    let writer = repository_write_lock(root, repo)
    defer writer.close()
    for phase in 0..<3 {
      if phase == 1 {
        writer.close()
      }
      if phase == 2 {
        first.close()
      }
      let started : String = pool.with_client(client => {
        ignore(
          client.execute(
            "UPDATE repository_file_garbage SET next_attempt_at=datetime('now')",
          ),
        )
        client
        .query_one("SELECT datetime('now') AS started")
        .get_name("started")
      })
      cleanup_deleted_repositories(pool, root)
      assert_true(@fs.exists("\{repo.git_dir(root)}/HEAD"))
      pool.with_client(client => {
        let row = client.query_one(
          "SELECT attempts,last_error,next_attempt_at>=datetime(?,'+1 second') AS deferred FROM repository_file_garbage",
          params=[started],
        )
        assert_eq((row.get_name("attempts") : Int64), 0L)
        assert_eq((row.get_name("last_error") : String), "")
        assert_true(row.get_name("deferred"))
      })
      if phase == 0 {
        continue
      }
      try create_managed_repository(pool, root, repo, "private", false) catch {
        @domain.BadRequest(message~) =>
          assert_true(message.contains("still being deleted"))
        err => raise err
      } noraise {
        _ => fail("created over a live reader")
      }
    }
    // Keep an unlocked handle to the inode across cleanup and the next reader.
    let retained = @fs.open(
      repository_reader_lock_path(root, 1L),
      mode=ReadWrite,
    )
    defer retained.close()
    second.close()
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE repository_file_garbage SET next_attempt_at=datetime('now')",
        ),
      )
    })
    cleanup_deleted_repositories(pool, root)
    assert_false(@fs.exists(repo.git_dir(root)))
    let same_id = repository_reader_lock(root, 1L)
    defer same_id.close()
    assert_false(retained.try_lock(Exclusive))
    same_id.close()
    assert_true(retained.try_lock(Exclusive))
    create_managed_repository(pool, root, repo, "private", false)
    assert_true(repository_settings(pool, actor, repo).scope.id != 1L)
  })
}

///|
async test "reader controls reject invalid identities and symlinks" {
  @test_support.with_git_test_repo((root, _) => {
    for id in [0L, -1L] {
      try ignore(repository_reader_lock(root, id)) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid reader identity")
      }
    }
    let path = repository_reader_lock_path(root, 8L)
    @fs.symlink(target="\{root}/missing", path)
    try ignore(repository_reader_lock(root, 8L)) catch {
      @gitops.Failure(_) => ()
      err => raise err
    } noraise {
      _ => fail("followed reader lock symlink")
    }
    @fs.remove(path)
    @fs.rmdir("\{root}/.locks/repository-readers")
    @fs.mkdir("\{root}/other")
    @fs.symlink(target="\{root}/other", "\{root}/.locks/repository-readers")
    try ignore(repository_reader_lock(root, 8L)) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("followed reader directory symlink")
    }
  })
}

///|
async test "cancelling a read holder or queued read releases its control handle" {
  @test_support.with_repository_test_data((_, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let started = @async.Semaphore(1, initial_value=0)
    @async.with_task_group(group => {
      let reader = group.spawn(() => {
        let lock = repository_read_lock(root, repo)
        defer lock.close()
        started.release()
        @async.CondVar::Cond().wait()
      })
      started.acquire()
      reader.cancel()
      try reader.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        err => raise err
      } noraise {
        _ => fail("read holder was not cancelled")
      }
      let writer = repository_write_lock(root, repo)
      defer writer.close()
      let queued : @async.Task[Unit] = group.spawn(() => {
        started.release()
        let lock = repository_read_lock(root, repo)
        defer lock.close()
        fail("cancelled reader acquired the writer's lock")
      })
      started.acquire()
      queued.cancel()
      try queued.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        err => raise err
      } noraise {
        _ => fail("queued read was not cancelled")
      }
      writer.close()
      let next = repository_write_lock(root, repo)
      defer next.close()
    })
  })
}
