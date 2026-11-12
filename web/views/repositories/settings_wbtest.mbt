///|
async test "delete settings require scoped CSRF exact name and immutable repository ID" {
  @web_testkit.with_repository_test_app((port, pool, root, alice, bob) => {
    let path = "/alice/demo/settings"
    let (page, html) = @web_testkit.http_get_path_with_cookie(port, path, alice)
    assert_eq(page.code, 200)
    assert_true(html.contains("title=\"Settings\" aria-current=\"page\""))
    assert_true(html.contains("There is no recovery period"))
    let csrf = @web_testkit.extract_attr(
      html, "name=\"csrf_token\"", "value=\"",
    )
    let id = @web_testkit.extract_attr(
      html, "name=\"repository_id\"", "value=\"",
    )
    for
      token in [
        "",
        "bad",
        @web_testkit.repository_test_token(port, "alice", alice),
      ] {
      let (response, _) = @web_testkit.http_post_path_with_cookie(
        port,
        path + "/delete",
        "csrf_token=\{token}&repository_id=\{id}&confirmation=alice/demo",
        alice,
      )
      assert_eq(response.code, 403)
    }
    let (outsider, _) = @web_testkit.http_get_path_with_cookie(port, path, bob)
    assert_eq(outsider.code, 404)
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id,user_id,role) VALUES(1,2,'member')",
        ),
      )
    })
    let (member_response, _) = @web_testkit.http_get_path_with_cookie(
      port, path, bob,
    )
    assert_eq(member_response.code, 403)
    let (_, member_html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", bob,
    )
    assert_false(member_html.contains("href=\"/alice/demo/settings\""))
    let (forged, _) = @web_testkit.http_post_path_with_cookie(
      port,
      path + "/delete",
      "csrf_token=\{csrf}&repository_id=\{id}&confirmation=alice/demo",
      bob,
    )
    assert_eq(forged.code, 403)
    for
      (submitted_id, confirmation) in [
        (id, "demo"),
        ("999", "alice/demo"),
        ("", "alice/demo"),
      ] {
      let (response, body) = @web_testkit.http_post_path_with_cookie(
        port,
        path + "/delete",
        "csrf_token=\{csrf}&repository_id=\{submitted_id}&confirmation=\{confirmation}",
        alice,
      )
      assert_eq(response.code, 400)
      assert_true(body.contains("role=\"alert\""))
      assert_true(body.contains("name=\"confirmation\""))
    }
    let body = "csrf_token=\{csrf}&repository_id=\{id}&confirmation=alice/demo"
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO repository_mirror(repository_id,creator_id,url,active,force_push,prune,status)
          #|VALUES(1,1,'git@remote.example:demo.git',1,0,0,'syncing');
        ),
      )
    })
    let (busy, busy_html) = @web_testkit.http_post_path_with_cookie(
      port,
      path + "/delete",
      body,
      alice,
    )
    assert_eq(busy.code, 400)
    assert_true(busy_html.contains("a mirror is syncing"))
    assert_true(busy_html.contains("role=\"alert\""))
    pool.with_client(client => {
      ignore(client.execute("DELETE FROM repository_mirror"))
    })
    let (deleted, _) = @web_testkit.http_post_path_with_cookie(
      port,
      path + "/delete",
      body,
      alice,
    )
    assert_eq(deleted.code, 303)
    assert_true(deleted.headers.get("location") is Some("/alice"))
    for suffix in ["", "/settings", "/issues", "/merge-requests", "/pipelines"] {
      let (response, _) = @web_testkit.http_get_path_with_cookie(
        port,
        "/alice/demo" + suffix,
        alice,
      )
      assert_eq(response.code, 404)
    }
    let (repeated, _) = @web_testkit.http_post_path_with_cookie(
      port,
      path + "/delete",
      body,
      alice,
    )
    assert_eq(repeated.code, 404)
    assert_true(
      @repository.run_next_repository_deletion(
        pool,
        root,
        cleanup_attachments=ids => {
          @attachments.cleanup_repository_files(root, ids)
        },
        cleanup_artifacts=keys => {
          @pipeline.Coordinator::new(pool).cleanup_repository_files(root, keys)
        },
      ),
    )
    @repository.create_managed_repository(
      pool,
      root,
      { owner: "alice", name: "demo", },
      "private",
      false,
    )
    let (old_form, _) = @web_testkit.http_post_path_with_cookie(
      port,
      path + "/delete",
      body,
      alice,
    )
    assert_eq(old_form.code, 403)
    let (replacement, _) = @web_testkit.http_get_path_with_cookie(
      port, path, alice,
    )
    assert_eq(replacement.code, 200)
  })
}

///|
async test "permanent deletion cascades business records and cleans only the captured files" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let attachment = @attachments.upload(
      pool, root, scope, actor, "data.txt", b"repository data",
    )
    let keep = "f".repeat(64)
    let artifact = "a".repeat(64)
    let cache = "b".repeat(64)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO issue(id,repository_id,number,author_id,title) VALUES(99,1,1,1,'Delete me'),(100,2,1,1,'Keep me');
          #|INSERT INTO issue_activity(issue_id,actor_id,kind,body) VALUES(99,1,'comment','Delete me');
          #|INSERT INTO merge_request(id,repository_id,number,author_id,title,source_branch,target_branch) VALUES(99,1,1,1,'Delete me','feature','main');
          #|INSERT INTO merge_activity(merge_request_id,actor_id,kind,body) VALUES(99,1,'comment','Delete me');
          #|INSERT INTO branch_rule(repository_id,branch) VALUES(1,'main');
          #|INSERT INTO repository_secret(repository_id,name,value,branch,workflow_path) VALUES(1,'SECRET','value','main','.github/workflows/ci.yml');
          #|INSERT INTO repository_variable(repository_id,name,value) VALUES(1,'REGION','test');
          #|INSERT INTO repository_deploy_key(repository_id,title,public_key,fingerprint,creator_id) VALUES(1,'Old key','old-public-key','old-fingerprint',1);
          #|INSERT INTO repository_mirror(id,repository_id,creator_id,url,active,force_push,prune,status) VALUES(99,1,1,'git@remote.example:demo.git',0,0,0,'disabled');
          #|INSERT INTO mirror_ssh_key(mirror_id,private_key,public_key) VALUES(99,'private','public');
          #|INSERT INTO repository_webhook(id,repository_id,creator_id,url,secret,events) VALUES(99,1,1,'https://example.com/hook','secret','issue');
          #|INSERT INTO webhook_event(id,repository_id,event_key,kind,payload) VALUES(99,1,'delete-test','issue','{}');
          #|INSERT INTO pipeline_run(id,repository_id,number,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,source_ref,definition_version,workflow_source,definition_json,status,conclusion)
          #|VALUES(99,1,1,1,'.github/workflows/ci.yml','CI','main','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/moonhub/test',1,'','{}','completed','success');
          #|INSERT INTO pipeline_job(id,run_id,job_key,ordinal,status,conclusion) VALUES(99,99,'test',0,'completed','success');
          #|INSERT INTO pipeline_job_attempt(id,job_id,number,status,conclusion,finished_at) VALUES(99,99,1,'completed','success',datetime('now'));
          #|INSERT INTO pipeline_log_chunk(attempt_id,sequence,step_id,stream,content,payload_hash) VALUES(99,1,'test','stdout','log','hash');
        ),
      )
    })
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO attachment_reference(attachment_id,issue_id) VALUES(?,99)",
          params=[attachment.id],
        ),
      )
      for (key, kind) in [(artifact, "artifact"), (cache, "cache")] {
        ignore(
          client.execute(
            "INSERT INTO pipeline_artifact(repository_id,run_id,attempt_id,name,storage_key,state,created_ms,expires_ms,kind) VALUES(1,99,99,?,?,'ready',0,9999999999999,?)",
            params=[kind, key, kind],
          ),
        )
      }
      ignore(
        client.execute(
          "INSERT INTO pipeline_cache(artifact_id,repository_id,scope,key,version,state,created_ms,last_access_ms) SELECT id,1,'main','cache','v1','ready',0,0 FROM pipeline_artifact WHERE kind='cache'",
        ),
      )
    })
    for key in [artifact, cache, keep] {
      @fs.mkdir(root + "/.pipeline-artifacts/" + key, recursive=true)
      @fs.write_file(root + "/.pipeline-artifacts/" + key + "/archive", "data")
    }
    @fs.write_file(root + "/.attachments/" + keep, "keep")
    @fs.mkdir(root + "/.mirrors/99", recursive=true)
    @fs.write_file(root + "/.mirrors/99/state", "old mirror")
    @fs.mkdir(root + "/.mirrors/100")
    @fs.write_file(root + "/.mirrors/100/keep", "keep")
    let (_, html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/settings", cookie,
    )
    let csrf = @web_testkit.extract_attr(
      html, "name=\"csrf_token\"", "value=\"",
    )
    let (response, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/settings/delete",
      "csrf_token=\{csrf}&repository_id=1&confirmation=alice/demo",
      cookie,
    )
    assert_eq(response.code, 303)
    pool.with_client(client => {
      for
        table in [
          "merge_request", "merge_activity", "issue_activity", "branch_rule", "repository_secret",
          "repository_variable", "repository_mirror", "mirror_ssh_key", "repository_webhook",
          "webhook_event", "webhook_delivery", "pipeline_run", "pipeline_job", "pipeline_job_attempt",
          "pipeline_log_chunk", "pipeline_artifact", "pipeline_cache", "attachment",
          "attachment_reference",
        ] {
        assert_true(
          client.query_all("SELECT * FROM \{table}").is_empty(),
          msg=table,
        )
      }
      assert_eq(client.query_all("SELECT * FROM issue").length(), 1)
      let key = client.query_one("SELECT * FROM repository_deploy_key")
      assert_true((key.get_name("repository_id") : Int64?) is None)
      assert_true((key.get_name("revoked_at") : String?) is Some(_))
      assert_eq(
        client.query_all("SELECT * FROM repository_deletion_resource").length(),
        4,
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
    assert_true(
      @repository.run_next_repository_deletion(
        pool,
        root,
        cleanup_attachments=ids => {
          @attachments.cleanup_repository_files(root, ids)
        },
        cleanup_artifacts=keys => {
          @pipeline.Coordinator::new(pool).cleanup_repository_files(root, keys)
        },
      ),
    )
    for
      path in [
        "alice/demo.git",
        ".attachments/" + attachment.id,
        ".pipeline-artifacts/" + artifact,
        ".pipeline-artifacts/" + cache,
        ".mirrors/99",
      ] {
      assert_false(@fs.exists(root + "/" + path), msg=path)
    }
    for
      path in [
        ".attachments/" + keep,
        ".pipeline-artifacts/" + keep + "/archive",
        ".mirrors/100/keep",
      ] {
      assert_eq(
        @fs.read_file(root + "/" + path).text(),
        if path.has_suffix("archive") {
          "data"
        } else {
          "keep"
        },
      )
    }
    pool.with_client(client => {
      assert_true(
        client.query_all("SELECT * FROM repository_deletion").is_empty(),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
