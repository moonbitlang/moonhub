///|
async test "busy cleanup beyond a full batch cannot starve later Git and mirror tasks" {
  @test_support.with_repository_test_data((pool, root) => {
    let readers : Array[@fs.File] = []
    defer (for reader in readers {
      reader.close()
    })
    for i in 0..<105 {
      let id = i.to_int64() + 100L
      readers.push(repository_reader_lock(root, id))
      pool.with_client(client => {
        ignore(
          client.execute(
            "INSERT INTO repository_file_garbage(repository_id,owner,name,kind,resource_id,path,next_attempt_at) VALUES(?,'alice',?,'git',?,?,datetime('now','-1 minute'))",
            params=[id, "busy\{i}", id, "alice/busy\{i}.git"],
          ),
        )
      })
    }
    @fs.mkdir("\{root}/.mirrors/999", recursive=true)
    @fs.mkdir("\{root}/alice/gone.git")
    @fs.write_file("\{root}/alice/gone.git/HEAD", "deleted repository data")
    let mirror = mirror_lock(root, 999L)
    defer mirror.close()
    pool.with_client(client => {
      client.batch_execute(
        "INSERT INTO repository_file_garbage(repository_id,owner,name,kind,resource_id,path,next_attempt_at) VALUES(998,'alice','gone','git',998,'alice/gone.git',datetime('now','-1 minute')),(999,'alice','mirror','mirror',999,'.mirrors/999',datetime('now','-1 minute'));",
      )
    })
    cleanup_deleted_repositories(pool, root)
    pool.with_client(client => {
      assert_eq(
        client.query_all("SELECT id FROM repository_file_garbage").length(),
        107,
      )
      // Make retried work due again, but still newer than unvisited work. Ordering
      // by ID alone would repeatedly choose the first hundred busy repositories.
      ignore(
        client.execute(
          "UPDATE repository_file_garbage SET next_attempt_at=datetime('now') WHERE next_attempt_at>datetime('now')",
        ),
      )
    })
    cleanup_deleted_repositories(pool, root)
    pool.with_client(client => {
      assert_eq(
        client.query_all("SELECT id FROM repository_file_garbage").length(),
        106,
      )
      assert_true(
        client.query_opt(
          "SELECT id FROM repository_file_garbage WHERE repository_id=998",
        )
        is None,
      )
      assert_true(
        client
        .query_all(
          "SELECT id FROM repository_file_garbage WHERE attempts<>0 OR last_error<>''",
        )
        .is_empty(),
      )
    })
    assert_false(@fs.exists("\{root}/alice/gone.git"))
    assert_true(@fs.exists("\{root}/.mirrors/999"))
    mirror.close()
    for reader in readers {
      reader.close()
    }
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE repository_file_garbage SET next_attempt_at=datetime('now')",
        ),
      )
    })
    cleanup_deleted_repositories(pool, root)
    cleanup_deleted_repositories(pool, root)
    assert_false(@fs.exists("\{root}/.mirrors/999"))
    pool.with_client(client => {
      assert_true(
        client.query_all("SELECT id FROM repository_file_garbage").is_empty(),
      )
    })
  })
}

///|
async test "deletion cleanup retries safely and blocks creation and import until Git is removed" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    delete_repository(pool, root, alice, repo, 1L, repo.path())
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
    for import_existing in [true, false] {
      try
        create_managed_repository(pool, root, repo, "private", import_existing)
      catch {
        @domain.BadRequest(message~) =>
          assert_true(message.contains("still being deleted"))
        err => raise err
      } noraise {
        _ => fail("reused a pending cleanup path")
      }
    }
    try
      enqueue_repository(pool, root, alice, team, "demo", "private", "")
    catch {
      @domain.BadRequest(message~) =>
        assert_true(message.contains("still being deleted"))
      err => raise err
    } noraise {
      _ => fail("enqueued over deleted data")
    }
    // Simulate a partial cleanup followed by a filesystem validation failure.
    @fs.remove("\{root}/alice/demo.git/description")
    @fs.rename(repo.git_dir(root), "\{root}/old.git")
    @fs.symlink(target="\{root}/old.git", repo.git_dir(root))
    cleanup_deleted_repositories(pool, root)
    assert_true(@fs.exists("\{root}/old.git/HEAD"))
    pool.with_client(client => {
      let row = client.query_one(
        "SELECT attempts,last_error FROM repository_file_garbage",
      )
      assert_eq((row.get_name("attempts") : Int64), 1L)
      assert_false((row.get_name("last_error") : String).is_empty())
      ignore(
        client.execute(
          "UPDATE repository_file_garbage SET next_attempt_at=datetime('now')",
        ),
      )
    })
    @fs.remove(repo.git_dir(root))
    @fs.rename("\{root}/old.git", repo.git_dir(root))
    cleanup_deleted_repositories(pool, root)
    cleanup_deleted_repositories(pool, root)
    assert_false(@fs.exists(repo.git_dir(root)))
    create_managed_repository(pool, root, repo, "private", false)
    let rebuilt = repository_settings(pool, alice, repo)
    assert_true(rebuilt.scope.id != 1L)
    // An old confirmation cannot delete or change the new repository.
    try delete_repository(pool, root, alice, repo, 1L, repo.path()) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("old confirmation deleted a rebuilt repository")
    }
    try
      change_repository_visibility(
        pool, root, alice, repo, 1L, "private", "public",
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("old confirmation changed a rebuilt repository")
    }
    // A stale or corrupt task must leave a new repository untouched.
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO repository_file_garbage(repository_id,owner,name,kind,resource_id,path) VALUES(1,'alice','demo','git',1,'alice/demo.git')",
        ),
      )
    })
    cleanup_deleted_repositories(pool, root)
    assert_true(@fs.exists("\{repo.git_dir(root)}/HEAD"))
    assert_eq(repository_settings(pool, alice, repo).scope.id, rebuilt.scope.id)
  })
}

///|
async test "cleanup retains dangling symlinks and never releases their names" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    delete_repository(pool, root, actor, repo, 1L, repo.path())
    @fs.rmdir(repo.git_dir(root), recursive=true)
    @fs.symlink(target="\{root}/missing.git", repo.git_dir(root))
    cleanup_deleted_repositories(pool, root)
    pool.with_client(client => {
      assert_eq(
        client.query_all("SELECT * FROM repository_file_garbage").length(),
        1,
      )
      try
        ignore(
          client.execute(
            "INSERT INTO repository(team_id,name) VALUES(1,'demo')",
          ),
        )
      catch {
        _ => ()
      } noraise {
        _ => fail("database name reservation was bypassed")
      }
    })
  })
}

///|
async test "cleanup journals survive reopening and validate paths and missing files" {
  @test_support.with_git_test_repo((root, _) => {
    @async.with_task_group(group => {
      let path = "\{root}/cleanup.db"
      let pool = @database.new_db_pool({ path, }, group)
      @database.initialize_db(pool)
      pool.with_client(client => {
        client.batch_execute(
          "INSERT INTO repository_file_garbage(repository_id,owner,name,kind,resource_id,path) VALUES(8,'alice','demo','git',8,'alice/demo.git'),(9,'alice','missing','git',9,'alice/missing.git'),(10,'alice','escape','git',10,'../outside');",
        )
      })
      // Crash after removing the files but before deleting their durable journal.
      let control = repository_write_lock(root, {
        owner: "alice",
        name: "demo",
      })
      defer control.close()
      @fs.rmdir("\{root}/alice/demo.git", recursive=true)
      control.unlock()
      pool.close()
      let reopened = @database.new_db_pool({ path, }, group)
      defer reopened.close()
      @database.initialize_db(reopened)
      cleanup_deleted_repositories(reopened, root)
      assert_false(@fs.exists("\{root}/alice/demo.git"))
      reopened.with_client(client => {
        let rows = client.query_all(
          "SELECT path,attempts FROM repository_file_garbage",
        )
        assert_eq(rows.length(), 1)
        assert_eq((rows[0].get_name("path") : String), "../outside")
        assert_eq((rows[0].get_name("attempts") : Int64), 1L)
      })
    })
  })
}

///|
async test "cleanup serializes workers and removes mirror directories after a same-name rebuild" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let mirror = mirror_lock(root, 45L)
    mirror.close()
    @fs.mkdir("\{root}/.mirrors/45", recursive=true)
    @fs.write_file("\{root}/.mirrors/45/partial", "mirror staging")
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO repository_mirror(id,repository_id,creator_id,url,active,force_push,prune,status) VALUES(45,1,1,'git@example.test:repo',0,0,0,'disabled')",
        ),
      )
    })
    delete_repository(pool, root, alice, repo, 1L, repo.path())
    @fs.mkdir("\{root}/.repository-cleanup")
    let worker = @fs.open(
      "\{root}/.repository-cleanup/worker.lock",
      mode=ReadWrite,
      create_mode=OpenOrCreate,
    )
    assert_true(worker.try_lock(Exclusive))
    cleanup_deleted_repositories(pool, root)
    assert_true(@fs.exists(repo.git_dir(root)))
    worker.close()
    // Git was removed by an interrupted worker, while mirror data remains.
    @fs.rmdir(repo.git_dir(root), recursive=true)
    cleanup_deleted_repositories(pool, root)
    create_managed_repository(pool, root, repo, "private", false)
    cleanup_deleted_repositories(pool, root)
    assert_false(@fs.exists("\{root}/.mirrors/45"))
    assert_true(@fs.exists("\{repo.git_dir(root)}/HEAD"))
    // A corrupt task pointing at a live mirror must also fail closed.
    let live = mirror_lock(root, 46L)
    live.close()
    @fs.mkdir("\{root}/.mirrors/46", recursive=true)
    @fs.write_file("\{root}/.mirrors/46/keep", "live mirror")
    let rebuilt = repository_settings(pool, alice, repo)
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO repository_mirror(id,repository_id,creator_id,url,active,force_push,prune,status) VALUES(46,?,1,'git@example.test:repo',0,0,0,'disabled')",
          params=[rebuilt.scope.id],
        ),
      )
      ignore(
        client.execute(
          "INSERT INTO repository_file_garbage(repository_id,owner,name,kind,resource_id,path) VALUES(1,'alice','demo','mirror',46,'.mirrors/46')",
        ),
      )
    })
    cleanup_deleted_repositories(pool, root)
    assert_eq(@fs.read_file("\{root}/.mirrors/46/keep").text(), "live mirror")
  })
}
