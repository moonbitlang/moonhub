///|
async test "repository transfer excludes admitted Web readers and rejects scopes for reused names" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let source = @domain.parse_transport_repo("alice/demo.git")
    change_repository_visibility(
      pool, root, alice, source, 1L, "private", "public",
    )
    let scope = readable_repository_scope(pool, None, source)
    let transfer = () => {
      transfer_repository(
        pool,
        root,
        alice,
        source,
        scope.id,
        3L,
        source.path(),
      )
    }
    {
      let (reader, git_dir) = open_repository_read(pool, root, None, scope)
      defer reader.close()
      assert_eq(git_dir, source.git_dir(root))
      try transfer() catch {
        @domain.BadRequest(message~) =>
          assert_true(message.contains("Git read"))
        err => raise err
      } noraise {
        _ => fail("transfer moved a repository with an admitted Web reader")
      }
    }
    ignore(transfer())
    create_managed_repository(pool, root, source, "public", false)
    assert_true(readable_repository_scope(pool, None, source).id != scope.id)
    try open_repository_read(pool, root, None, scope) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      (reader, _) => {
        reader.close()
        fail("the original reader was admitted to the replacement repository")
      }
    }
  })
}

///|
async test "repository transfer preserves the Git history ID and data and switches namespace access" {
  @test_support.with_repository_test_data((pool, root) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let source : @domain.RepoId = { owner: "alice", name: "demo", }
    let target : @domain.RepoId = { owner: "bob", name: "demo", }
    let scope = repository_scope(pool, alice, source)
    let sha = @gitops.branch_sha(source.git_dir(root), "master")
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO issue(repository_id,number,author_id,title) VALUES(1,1,1,'Moved issue');
          #|INSERT INTO merge_request(repository_id,number,author_id,title,source_branch,target_branch) VALUES(1,1,1,'Moved PR','feature','master');
          #|INSERT INTO repository_release(repository_id,tag,commit_sha,source_ref,title,author_id) VALUES(1,'v1','test-sha','refs/tags/v1','Moved release',1);
          #|INSERT INTO pipeline_run(repository_id,number,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,source_ref,definition_version,workflow_source,definition_json,status,conclusion) VALUES(1,1,1,'ci.yml','CI','master','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/moonhub/test',1,'','{}','completed','success');
        ),
      )
    })
    let moved = transfer_repository(
      pool,
      root,
      admin,
      source,
      scope.id,
      2L,
      source.path(),
    )
    assert_eq(moved.path(), target.path())
    assert_eq(repository_scope(pool, bob, target).id, scope.id)
    assert_eq(repository_scope(pool, bob, target).team_id, 2L)
    assert_false(can_read_repository(pool, Some(alice), target))
    assert_false(can_read_repository(pool, None, target))
    assert_false(can_read_repository(pool, Some(admin), source))
    assert_false(@fs.exists(source.git_dir(root)))
    assert_eq(@gitops.branch_sha(target.git_dir(root), "master"), sha)
    pool.with_client(client => {
      for
        table in [
          "issue", "merge_request", "repository_release", "pipeline_run",
        ] {
        let row = client.query_one("SELECT repository_id FROM \{table}")
        assert_eq((row.get_name("repository_id") : Int64), scope.id)
      }
      let audit = client.query_one(
        "SELECT actor_id,detail FROM repository_audit WHERE repository_id=1 AND kind='repository_transferred'",
      )
      assert_eq((audit.get_name("actor_id") : Int64), admin.id)
      assert_eq((audit.get_name("detail") : String), "alice/demo -> bob/demo")
      assert_true(
        client.query_all("SELECT * FROM repository_transfer").is_empty(),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
    create_managed_repository(pool, root, source, "private", false)
    assert_true(repository_scope(pool, alice, source).id != scope.id)
    assert_eq(@gitops.branch_sha(target.git_dir(root), "master"), sha)
  })
}

///|
async test "repository transfer refuses busy resources or a conflicting destination without overwriting files" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let source : @domain.RepoId = { owner: "alice", name: "demo", }
    let target : @domain.RepoId = { owner: "workshop", name: "demo", }
    let attempt = () => {
      transfer_repository(pool, root, alice, source, 1L, 3L, source.path())
    }
    let reader = repository_reader_lock(root, 1L)
    try attempt() catch {
      @domain.BadRequest(message~) => assert_true(message.contains("Git read"))
      err => raise err
    } noraise {
      _ => fail("transfer moved a repository with an admitted reader")
    }
    reader.close()
    pool.with_client(client => {
      client.batch_execute(
        "INSERT INTO merge_request(repository_id,number,author_id,title,source_branch,target_branch) VALUES(1,1,1,'Queued PR','feature','master'); INSERT INTO merge_job(merge_request_id,actor_id,version) VALUES(1,1,1);",
      )
    })
    try attempt() catch {
      @domain.BadRequest(message~) =>
        assert_true(message.contains("merge is queued"))
      err => raise err
    } noraise {
      _ => fail("transfer moved a repository with a queued merge")
    }
    pool.with_client(client => {
      client.batch_execute(
        "DELETE FROM merge_job; INSERT INTO repository(team_id,name,ready) VALUES(3,'demo',0);",
      )
    })
    try attempt() catch {
      @domain.BadRequest(message~) =>
        assert_true(message.contains("name is already taken"))
      err => raise err
    } noraise {
      _ => fail("transfer replaced a provisioning repository")
    }
    pool.with_client(client => {
      client.batch_execute(
        "DELETE FROM repository WHERE team_id=3; INSERT INTO repository_file_garbage(repository_id,owner,name,kind,resource_id,path) VALUES(9,'workshop','demo','git',9,'workshop/demo.git');",
      )
    })
    try attempt() catch {
      @domain.BadRequest(message~) =>
        assert_true(message.contains("files are still being deleted"))
      err => raise err
    } noraise {
      _ => fail("transfer used a path reserved for deletion")
    }
    pool.with_client(client => {
      client.batch_execute("DELETE FROM repository_file_garbage")
    })
    @fs.mkdir(target.git_dir(root))
    let marker = "\{target.git_dir(root)}/keep"
    @fs.write_file(marker, "existing data")
    try attempt() catch {
      @domain.BadRequest(message~) =>
        assert_true(message.contains("directory already exists"))
      err => raise err
    } noraise {
      _ => fail("transfer overwrote an unregistered directory")
    }
    assert_eq(@fs.read_file(marker).text(), "existing data")
    assert_eq(repository_scope(pool, alice, source).id, 1L)
    assert_true(@fs.exists(source.git_dir(root)))
  })
}

///|
async test "repository transfer rechecks destination authorization after waiting on its lock" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let source : @domain.RepoId = { owner: "alice", name: "demo", }
    let target : @domain.RepoId = { owner: "workshop", name: "demo", }
    let lock = repository_write_lock(root, target)
    @async.with_task_group(group => {
      defer lock.close()
      let pending = group.spawn(() => {
        try
          transfer_repository(pool, root, alice, source, 1L, 3L, source.path())
        catch {
          @domain.Forbidden(_) => ()
          err => raise err
        } noraise {
          _ => fail("transfer accepted revoked destination permission")
        }
      })
      let source_lock = repository_lock_path(root, source)
      @async.with_timeout(5000, () => {
        while @gitops.try_file_lock(source_lock) is Some(available) {
          available.close()
          @async.sleep(10)
        }
      })
      pool.with_client(client => {
        client.batch_execute(
          "UPDATE team_member SET role='member' WHERE team_id=3 AND user_id=1",
        )
      })
      lock.close()
      pending.wait()
    })
    assert_false(@fs.exists(target.git_dir(root)))
    assert_eq(repository_scope(pool, alice, source).id, 1L)
  })
}

///|
async test "repository transfer rolls back a Git move when the final database update fails" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let source : @domain.RepoId = { owner: "alice", name: "demo", }
    let target : @domain.RepoId = { owner: "workshop", name: "demo", }
    let sha = @gitops.branch_sha(source.git_dir(root), "master")
    pool.with_client(client => {
      client.batch_execute(
        "CREATE TRIGGER reject_transfer BEFORE UPDATE OF team_id ON repository BEGIN SELECT RAISE(ABORT,'injected transfer failure'); END;",
      )
    })
    try
      transfer_repository(pool, root, alice, source, 1L, 3L, source.path())
    catch {
      err => assert_true("\{err}".contains("injected transfer failure"))
    } noraise {
      _ => fail("transfer ignored database update failure")
    }
    assert_eq(repository_scope(pool, alice, source).id, 1L)
    assert_false(@fs.exists(target.git_dir(root)))
    assert_eq(@gitops.branch_sha(source.git_dir(root), "master"), sha)
    pool.with_client(client => {
      assert_true(
        client.query_all("SELECT * FROM repository_transfer").is_empty(),
      )
      assert_true(client.query_all("SELECT * FROM repository_audit").is_empty())
    })
  })
}

///|
async test "transfer recovery waits for the name lock and restores the source after an interrupted move" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let source : @domain.RepoId = { owner: "alice", name: "demo", }
    let target : @domain.RepoId = { owner: "workshop", name: "demo", }
    let sha = @gitops.branch_sha(source.git_dir(root), "master")
    @fs.mkdir("\{root}/workshop")
    for moved in [false, true] {
      pool.with_client(client => {
        client.batch_execute(
          "INSERT INTO repository_transfer(repository_id,target_team_id,name) VALUES(1,3,'demo'); UPDATE repository SET ready=0 WHERE id=1;",
        )
      })
      if moved {
        @fs.rename(source.git_dir(root), target.git_dir(root), replace=false)
      }
      assert_false(can_read_repository(pool, Some(alice), source))
      assert_false(can_read_repository(pool, Some(alice), target))
      try
        create_managed_repository(pool, root, target, "private", false)
      catch {
        @domain.BadRequest(message~) =>
          assert_true(message.contains("unfinished transfer"))
        err => raise err
      } noraise {
        _ => fail("repository creation used a name reserved by a transfer")
      }
      let lock = repository_write_lock(root, target)
      ignore(recover_repository_transfers(pool, root))
      assert_false(can_read_repository(pool, Some(alice), source))
      lock.close()
      ignore(recover_repository_transfers(pool, root))
      assert_eq(repository_scope(pool, alice, source).id, 1L)
      assert_false(@fs.exists(target.git_dir(root)))
      assert_eq(@gitops.branch_sha(source.git_dir(root), "master"), sha)
    }
    create_managed_repository(pool, root, target, "private", false)
    assert_true(repository_scope(pool, alice, target).id != 1L)
  })
}
