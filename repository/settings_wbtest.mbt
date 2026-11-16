///|
async test "repository visibility changes enforce managers and current state" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let admin = @identity.active_user_by_name(pool, "admin")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let settings = repository_settings(pool, alice, repo)
    assert_eq(settings.visibility, "private")
    assert_false(can_read_repository(pool, None, repo))
    try repository_settings(pool, bob, repo) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("outsider accessed settings")
    }
    change_repository_visibility(
      pool,
      root,
      admin,
      repo,
      settings.scope.id,
      "private",
      "public",
    )
    assert_true(can_read_repository(pool, None, repo))
    try
      change_repository_visibility(
        pool,
        root,
        alice,
        repo,
        settings.scope.id,
        "private",
        "public",
      )
    catch {
      @domain.BadRequest(message~) =>
        assert_true(message.contains("visibility has changed"))
      err => raise err
    } noraise {
      _ => fail("accepted stale visibility")
    }
    for role in ["member", "admin", "owner"] {
      pool.with_client(client => {
        ignore(
          client.execute(
            "INSERT INTO team_member(team_id,user_id,role) VALUES(1,2,?) ON CONFLICT(team_id,user_id) DO UPDATE SET role=excluded.role",
            params=[role],
          ),
        )
      })
      if role == "admin" || role == "owner" {
        assert_eq(repository_settings(pool, bob, repo).visibility, "public")
      } else {
        try repository_settings(pool, bob, repo) catch {
          @domain.Forbidden(_) => ()
          err => raise err
        } noraise {
          _ => fail("non-manager accessed settings")
        }
      }
    }
    change_repository_visibility(
      pool,
      root,
      alice,
      repo,
      settings.scope.id,
      "public",
      "private",
    )
    assert_false(can_read_repository(pool, None, repo))
    for (previous, target) in [("private", "private"), ("private", "unknown")] {
      try
        change_repository_visibility(
          pool,
          root,
          alice,
          repo,
          settings.scope.id,
          previous,
          target,
        )
      catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid transition")
      }
    }
  })
}

///|
async test "waiting settings writes recheck identity and authorization" {
  for action in ["visibility", "delete"] {
    @test_support.with_repository_test_data((pool, root) => {
      let alice = @identity.active_user_by_name(pool, "alice")
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      for mode in ["permission", "identity"] {
        let settings = repository_settings(pool, alice, repo)
        let dir = resolve_repository_dir(root, repo)
        let lock = @gitops.repository_write_lock(dir)
        @async.with_task_group(group => {
          let waiting = group.spawn(() => {
            try {
              if action == "visibility" {
                change_repository_visibility(
                  pool,
                  root,
                  alice,
                  repo,
                  settings.scope.id,
                  "private",
                  "public",
                )
              } else {
                delete_repository(
                  pool,
                  root,
                  alice,
                  repo,
                  settings.scope.id,
                  repo.path(),
                )
              }
            } catch {
              @domain.Forbidden(_) | @domain.BadRequest(_) => ()
              err => raise err
            } noraise {
              _ => fail("waiting operation skipped revalidation")
            }
          })
          @async.sleep(50)
          pool.with_client(client => {
            if mode == "permission" {
              ignore(
                client.execute(
                  "UPDATE team_member SET role='member' WHERE team_id=1 AND user_id=1",
                ),
              )
            } else {
              client.batch_execute(
                "DELETE FROM repository WHERE id=1; INSERT INTO repository(team_id,name,visibility) VALUES(1,'demo','private');",
              )
            }
          })
          lock.close()
          waiting.wait()
        })
        pool.with_client(client => {
          ignore(
            client.execute(
              "UPDATE team_member SET role='owner' WHERE team_id=1 AND user_id=1",
            ),
          )
        })
        assert_eq(repository_settings(pool, alice, repo).visibility, "private")
      }
    })
  }
}

///|
async test "deletion rejects unfinished Actions syncing mirrors and sending webhooks" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    pool.with_client(client => {
      client.batch_execute(
        "INSERT INTO pipeline_run(repository_id,number,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,source_ref,definition_version,workflow_source,definition_json) VALUES(1,1,1,'ci.yml','CI','master','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/moonhub/test',1,'','{}');",
      )
    })
    for
      (label, release) in [
        (
          "Actions", "UPDATE pipeline_run SET status='completed',conclusion='cancelled'; INSERT INTO repository_mirror(repository_id,creator_id,url,active,force_push,prune,status) VALUES(1,1,'git@example.test:demo',1,0,0,'syncing');",
        ),
        (
          "mirror", "UPDATE repository_mirror SET status='succeeded'; INSERT INTO repository_webhook(repository_id,creator_id,url,secret,events) VALUES(1,1,'https://example.test/hook','secret','[]'); INSERT INTO webhook_event(repository_id,event_key,kind,payload) VALUES(1,'test','ping','{}'); INSERT INTO webhook_delivery(webhook_id,event_id,status) VALUES(1,last_insert_rowid(),'sending');",
        ),
        ("webhook", "UPDATE webhook_delivery SET status='succeeded';"),
      ] {
      try delete_repository(pool, root, alice, repo, 1L, repo.path()) catch {
        @domain.BadRequest(message~) => assert_true(message.contains(label))
        err => raise err
      } noraise {
        _ => fail("deleted a busy repository")
      }
      assert_true(can_read_repository(pool, Some(alice), repo))
      pool.with_client(client => {
        assert_true(
          client.query_all("SELECT * FROM repository_file_garbage").is_empty(),
        )
        client.batch_execute(release)
      })
    }
    try delete_repository(pool, root, alice, repo, 1L, "alice/Demo") catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted incorrect confirmation")
    }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO pipeline_job(id,run_id,job_key,ordinal,status,conclusion) VALUES(1,1,'build',0,'completed','cancelled');
          #|INSERT INTO pipeline_job_attempt(id,job_id,number,status,conclusion,finished_at) VALUES(1,1,1,'completed','cancelled',datetime('now'));
          #|INSERT INTO pipeline_artifact(id,repository_id,run_id,attempt_id,name,storage_key,state,created_ms,expires_ms,kind) VALUES(1,1,1,1,'artifact','artifact-key','ready',1,999999,'artifact'),(2,1,1,1,'cache','cache-key','ready',1,999999,'cache');
          #|INSERT INTO pipeline_cache(artifact_id,repository_id,scope,key,version,state,created_ms,last_access_ms) VALUES(2,1,'refs/heads/master','cache','v1','ready',1,1);
          #|INSERT INTO repository_release(id,repository_id,tag,commit_sha,source_ref,title,author_id) VALUES(1,1,'v1','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/moonhub/releases/1','Version 1',1);
          #|INSERT INTO release_asset(release_id,name,media_type,state,commit_sha,storage_key,location,expires_ms) VALUES(1,'app.zip','application/zip','ready','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','release-key','legacy-fs',999999);
        ),
      )
    })
    delete_repository(pool, root, alice, repo, 1L, repo.path())
    assert_false(can_read_repository(pool, Some(alice), repo))
    assert_true(@fs.exists(repo.git_dir(root)))
    pool.with_client(client => {
      for
        table in [
          "pipeline_run", "pipeline_job", "pipeline_job_attempt", "pipeline_artifact",
          "pipeline_cache", "repository_release", "release_asset", "repository_mirror",
          "repository_webhook", "webhook_event", "webhook_delivery",
        ] {
        assert_true(client.query_all("SELECT * FROM \{table}").is_empty())
      }
      assert_eq(
        client.query_all("SELECT * FROM repository_file_garbage").length(),
        2,
      )
      assert_eq(
        client.query_all("SELECT * FROM pipeline_blob_garbage").length(),
        2,
      )
      assert_eq(
        client.query_all("SELECT * FROM release_blob_garbage").length(),
        1,
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
