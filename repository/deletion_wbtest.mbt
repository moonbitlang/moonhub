///|
async test "permanent deletion requires a current repository manager and exact identity" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = repository_scope(pool, alice, repo)
    for confirmation in ["demo", "alice/other", " alice/demo", "alice/demo "] {
      try
        delete_repository(pool, root, alice, repo, scope.id, confirmation)
      catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted incorrect confirmation")
      }
    }
    try
      delete_repository(pool, root, alice, repo, scope.id + 1, repo.path())
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted stale identity")
    }
    try delete_repository(pool, root, bob, repo, scope.id, repo.path()) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("outsider deleted repository")
    }
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id,user_id,role) VALUES(1,2,'member')",
        ),
      )
    })
    try delete_repository(pool, root, bob, repo, scope.id, repo.path()) catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("ordinary member deleted repository")
    }
    delete_repository(pool, root, alice, repo, scope.id, repo.path())
    assert_false(can_access_repository(pool, alice, repo, Read))
    assert_false(can_access_repository(pool, alice, repo, Write))
    try
      delete_repository(pool, root, alice, repo, scope.id, repo.path())
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("duplicate deletion succeeded")
    }
  })
}

///|
async test "organization owners admins and site administrators can permanently delete" {
  @test_support.with_repository_test_data((pool, root) => {
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id,user_id,role) VALUES(3,2,'admin')",
        ),
      )
    })
    for
      (actor_name, name) in [
        ("alice", "alice"),
        ("bob", "bob"),
        ("admin", "admin"),
        ("alice", "trailing.git"),
      ] {
      let actor = @identity.active_user_by_name(pool, actor_name)
      let repo : @domain.RepoId = { owner: "workshop", name, }
      create_managed_repository(pool, root, repo, "private", false)
      let scope = repository_scope(pool, actor, repo)
      delete_repository(pool, root, actor, repo, scope.id, repo.path())
      assert_false(can_access_repository(pool, actor, repo, Read))
    }
    for _ in 0..<4 {
      assert_true(
        run_next_repository_deletion(pool, root, cleanup_attachments=_ => (), cleanup_artifacts=_ => {
          ()
        }),
      )
    }
    assert_false(@fs.exists(root + "/workshop/trailing.git.git"))
    // Site-admin flags on a previously loaded actor cannot survive demotion.
    let admin = @identity.active_user_by_name(pool, "admin")
    pool.with_client(client => {
      ignore(client.execute("UPDATE \"user\" SET is_site_admin=0 WHERE id=3"))
    })
    try
      delete_repository(
        pool,
        root,
        admin,
        { owner: "alice", name: "demo", },
        1,
        "alice/demo",
      )
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("demoted administrator deleted repository")
    }
  })
}

///|
async test "active CI and mirror transfers prevent deletion without leaving a cleanup job" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO pipeline_run(id,repository_id,number,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,source_ref,definition_version,workflow_source,definition_json)
          #|VALUES(99,1,1,1,'.github/workflows/ci.yml','CI','main','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/moonhub/test',1,'','{}');
        ),
      )
    })
    try delete_repository(pool, root, actor, repo, 1, repo.path()) catch {
      @domain.BadRequest(message~) => assert_true(message.contains("CI tasks"))
      err => raise err
    } noraise {
      _ => fail("deleted active CI")
    }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|UPDATE pipeline_run SET status='completed',conclusion='cancelled';
          #|INSERT INTO repository_mirror(repository_id,creator_id,url,active,force_push,prune,status)
          #|VALUES(1,1,'git@remote.example:demo.git',1,0,0,'syncing');
        ),
      )
    })
    try delete_repository(pool, root, actor, repo, 1, repo.path()) catch {
      @domain.BadRequest(message~) =>
        assert_true(message.contains("mirror is syncing"))
      err => raise err
    } noraise {
      _ => fail("deleted active mirror")
    }
    pool.with_client(client => {
      assert_true(
        client.query_all("SELECT * FROM repository_deletion").is_empty(),
      )
      ignore(client.execute("UPDATE repository_mirror SET status='succeeded'"))
    })
    delete_repository(pool, root, actor, repo, 1, repo.path())
  })
}

///|
async test "cleanup retries partial deletion across restart and releases the name only on success" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    delete_repository(pool, root, actor, repo, 1, repo.path())
    for import_existing in [false, true] {
      try
        create_managed_repository(pool, root, repo, "private", import_existing)
      catch {
        @domain.BadRequest(message~) =>
          assert_true(message.contains("cleanup is pending"))
        err => raise err
      } noraise {
        _ => fail("registered during cleanup")
      }
    }
    try
      enqueue_repository(pool, root, actor, team, "demo", "private", "")
    catch {
      @domain.BadRequest(message~) =>
        assert_true(message.contains("cleanup is pending"))
      err => raise err
    } noraise {
      _ => fail("enqueued during cleanup")
    }
    assert_true(
      run_next_repository_deletion(
        pool,
        root,
        cleanup_attachments=_ => {
          raise @domain.BadRequest(message="simulated disk failure")
        },
        cleanup_artifacts=_ => (),
      ),
    )
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT attempts FROM repository_deletion")
          .get_name("attempts") : Int64),
        1,
      )
      ignore(
        client.execute(
          "UPDATE repository_deletion SET next_attempt_at=datetime('now')",
        ),
      )
    })
    // Simulate a crash after some files were removed, then initialize anew.
    @fs.remove(repo.git_dir(root) + "/description")
    @database.initialize_db(pool)
    assert_true(
      run_next_repository_deletion(pool, root, cleanup_attachments=_ => (), cleanup_artifacts=_ => {
        ()
      }),
    )
    assert_false(@fs.exists(repo.git_dir(root)))
    assert_false(
      run_next_repository_deletion(pool, root, cleanup_attachments=_ => (), cleanup_artifacts=_ => {
        ()
      }),
    )
    create_managed_repository(pool, root, repo, "private", false)
    assert_true(repository_scope(pool, actor, repo).id != 1)
    try delete_repository(pool, root, actor, repo, 1, repo.path()) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("old identity deleted a replacement")
    }
    assert_true(can_access_repository(pool, actor, repo, Read))
  })
}

///|
async test "cleanup refuses symlinks traversal and concurrent workers" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let keep = root + "/keep"
    @fs.mkdir(keep)
    @fs.write_file(keep + "/sentinel", "keep")
    for relative in ["../keep", "/keep", "alice/../keep", "", "alice//demo.git"] {
      try remove_cleanup_path(root, relative) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("unsafe cleanup path accepted")
      }
    }
    @fs.symlink(target=keep, repo.git_dir(root) + "/linked")
    delete_repository(pool, root, actor, repo, 1, repo.path())
    assert_true(
      run_next_repository_deletion(pool, root, cleanup_attachments=_ => (), cleanup_artifacts=_ => {
        ()
      }),
    )
    assert_eq(@fs.read_file(keep + "/sentinel").text(), "keep")
    pool.with_client(client => {
      assert_eq(
        client.query_all("SELECT * FROM repository_deletion").length(),
        1,
      )
      ignore(
        client.execute(
          "UPDATE repository_deletion SET next_attempt_at=datetime('now')",
        ),
      )
    })
    let lock = @fs.open(
      root + "/.repository-cleanup/worker.lock",
      mode=ReadWrite,
    )
    assert_true(lock.try_lock(Exclusive))
    assert_false(
      run_next_repository_deletion(pool, root, cleanup_attachments=_ => (), cleanup_artifacts=_ => {
        ()
      }),
    )
    lock.close()
    @fs.remove(repo.git_dir(root) + "/linked")
    assert_true(
      run_next_repository_deletion(pool, root, cleanup_attachments=_ => (), cleanup_artifacts=_ => {
        ()
      }),
    )
    assert_eq(@fs.read_file(keep + "/sentinel").text(), "keep")
  })
}

///|
async test "deletion serializes with writes and rejects requests queued for the deleted identity" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let lock = @gitops.repository_write_lock(repo.git_dir(root))
    let mut deleted = false
    @async.with_task_group(group => {
      let task = group.spawn(() => {
        delete_repository(pool, root, actor, repo, 1, repo.path())
        deleted = true
      })
      @async.sleep(50)
      assert_false(deleted)
      assert_true(can_access_repository(pool, actor, repo, Write))
      lock.close()
      task.wait()
    })
    assert_true(deleted)
    // Queue an old writer behind deletion, then replace the database identity
    // while it is waiting. It must not enter its callback for the successor.
    pool.with_client(client => {
      ignore(client.execute("DELETE FROM repository_deletion"))
      ignore(
        client.execute("INSERT INTO repository(team_id,name) VALUES(1,'demo')"),
      )
    })
    let lock = @gitops.repository_write_lock(repo.git_dir(root))
    @async.with_task_group(group => {
      let task = group.spawn(() => {
        with_repository_write(pool, root, actor, repo, (_, _) => {
          fail("old writer entered successor")
        }) catch {
          @domain.NotFound(_) => ()
          err => raise err
        }
      })
      @async.sleep(50)
      pool.with_client(client => {
        ignore(client.execute("DELETE FROM repository WHERE name='demo'"))
        ignore(
          client.execute(
            "INSERT INTO repository(team_id,name) VALUES(1,'demo')",
          ),
        )
      })
      lock.close()
      task.wait()
    })
  })
}

///|
async test "old deploy keys and local imports remain bound to the deleted repository" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let key = @ssh.parse_ssh_public_key(@test_support.test_ssh_public_key)
    ignore(@ssh.add_repository_deploy_key(pool, actor, repo, "Deploy", key))
    assert_true(@ssh.authorized_ssh_key(pool, key) is Some(_))
    let addresses : SshAddressConfig = {
      public_override: Some({ host: "public.example", port: 2222, }),
      internal: Some({ host: "localhost", port: 22, }),
    }
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
    ignore(
      enqueue_repository(
        pool,
        root,
        actor,
        team,
        "copy",
        "private",
        "ssh://git@public.example:2222/alice/demo.git",
        addresses~,
      ),
    )
    let job = require_repository_job(pool, team, "copy")
    assert_eq(job.source_repository_id, Some(1L))
    delete_repository(pool, root, actor, repo, 1, repo.path())
    assert_true(@ssh.authorized_ssh_key(pool, key) is None)
    assert_true(
      run_next_repository_deletion(pool, root, cleanup_attachments=_ => (), cleanup_artifacts=_ => {
        ()
      }),
    )
    create_managed_repository(pool, root, repo, "private", false)
    assert_true(@ssh.authorized_ssh_key(pool, key) is None)
    for pending in [job, require_repository_job(pool, team, "copy")] {
      try repository_job_source(pool, actor, pending, addresses) catch {
        @domain.NotFound(_) => ()
        err => raise err
      } noraise {
        _ => fail("old import read the replacement repository")
      }
    }
    assert_true(run_next_repository_job(pool, root, None, addresses~))
    assert_eq(require_repository_job(pool, team, "copy").status, "failed")
    assert_false(@fs.exists(root + "/alice/copy.git"))
  })
}

///|
async test "cleanup resumes from a reopened database after interruption" {
  @test_support.with_git_test_repo((root, _) => {
    @async.with_task_group(group => {
      let path = root + "/deletion.db"
      let first = @database.new_db_pool({ path, }, group)
      @database.initialize_db(first)
      first.with_client(client => {
        client.batch_execute(
          (
            #|INSERT INTO "user"(id,name_key,display_name,password_hash) VALUES(1,'alice','Alice','test');
            #|INSERT INTO team(id,name_key,display_name,kind) VALUES(1,'alice','Alice','personal');
            #|INSERT INTO team_member(team_id,user_id,role) VALUES(1,1,'owner');
            #|INSERT INTO repository(id,team_id,name) VALUES(1,1,'demo');
          ),
        )
      })
      let actor = @identity.active_user_by_name(first, "alice")
      delete_repository(
        first,
        root,
        actor,
        { owner: "alice", name: "demo", },
        1,
        "alice/demo",
      )
      assert_true(
        run_next_repository_deletion(
          first,
          root,
          cleanup_attachments=_ => {
            raise @domain.BadRequest(message="disk unavailable")
          },
          cleanup_artifacts=_ => (),
        ),
      )
      first.close()
      let second = @database.new_db_pool({ path, }, group)
      defer second.close()
      @database.initialize_db(second)
      second.with_client(client => {
        assert_eq(
          (
            client
            .query_one("SELECT attempts FROM repository_deletion")
            .get_name("attempts") : Int64),
          1,
        )
        ignore(
          client.execute(
            "UPDATE repository_deletion SET next_attempt_at=datetime('now')",
          ),
        )
      })
      assert_true(
        run_next_repository_deletion(
          second,
          root,
          cleanup_attachments=_ => (),
          cleanup_artifacts=_ => (),
        ),
      )
      assert_false(@fs.exists(root + "/alice/demo.git"))
      second.with_client(client => {
        assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
      })
    })
  })
}
