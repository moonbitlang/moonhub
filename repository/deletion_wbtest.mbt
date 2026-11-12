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
