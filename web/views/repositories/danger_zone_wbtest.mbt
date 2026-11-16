///|
async fn danger_form_token(
  port : Int32,
  cookie : @http.Cookie,
  action : String,
) -> String {
  let (response, body) = @web_testkit.http_get_path_with_cookie(
    port,
    "/alice/demo/settings/danger-zone/\{action}",
    cookie,
  )
  assert_eq(response.code, 200)
  assert_eq(response.headers.get("cache-control"), Some("no-store"))
  @web_testkit.extract_attr(body, "name=\"csrf_token\"", "value=\"")
}

///|
async test "Danger Zone visibility forms update anonymous access and reject invalid or stale submissions" {
  @web_testkit.with_repository_test_app((port, pool, _, alice, _) => {
    let base = "/alice/demo/settings/danger-zone"
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port, base, alice,
    )
    assert_eq(response.code, 200)
    assert_true(body.contains("currently <strong>private</strong>"))
    assert_true(body.contains("aria-label=\"Dangerous settings\""))
    assert_true(body.contains("sidebar-footer--danger"))
    let visibility = danger_form_token(port, alice, "visibility")
    let deletion = danger_form_token(port, alice, "delete")
    assert_true(visibility != deletion)
    for token in ["", deletion] {
      let (invalid, _) = @web_testkit.http_post_path_with_cookie(
        port,
        "\{base}/visibility",
        "csrf_token=\{token}&repository_id=1&previous=private&visibility=public",
        alice,
      )
      assert_eq(invalid.code, 403)
    }
    let (wrong_id, wrong_body) = @web_testkit.http_post_path_with_cookie(
      port,
      "\{base}/visibility",
      "csrf_token=\{visibility}&repository_id=2&previous=private&visibility=public",
      alice,
    )
    assert_eq(wrong_id.code, 400)
    assert_true(wrong_body.contains("repository has changed"))
    for
      (previous, target, anonymous_status) in [
        ("private", "public", 200),
        ("public", "private", 404),
      ] {
      let (changed, _) = @web_testkit.http_post_path_with_cookie(
        port,
        "\{base}/visibility",
        "csrf_token=\{visibility}&repository_id=1&previous=\{previous}&visibility=\{target}",
        alice,
      )
      assert_eq(changed.code, 303)
      assert_eq(changed.headers.get("location"), Some(base))
      let (anonymous, body) = @http.get("http://127.0.0.1:\{port}/alice/demo")
      ignore(body.text())
      assert_eq(anonymous.code, anonymous_status)
      let (stale, body) = @web_testkit.http_post_path_with_cookie(
        port,
        "\{base}/visibility",
        "csrf_token=\{visibility}&repository_id=1&previous=\{previous}&visibility=\{target}",
        alice,
      )
      assert_eq(stale.code, 400)
      assert_true(body.contains("visibility has changed"))
      assert_true(body.contains("Confirm visibility change"))
    }
    let actor = @identity.active_user_by_name(pool, "alice")
    assert_eq(
      @repository.repository_settings(pool, actor, {
        owner: "alice",
        name: "demo",
      }).visibility,
      "private",
    )
  })
}

///|
async test "Danger Zone permissions follow settings for owners admins members and outsiders" {
  @test_support.with_git_test_repo((root, _) => {
    @web_testkit.with_ssh_settings_app(
      (port, pool, alice, bob, admin) => {
        let base = "/alice/demo/settings/danger-zone"
        for cookie in [alice, admin] {
          for suffix in ["", "/visibility", "/delete"] {
            let (allowed, _) = @web_testkit.http_get_path_with_cookie(
              port,
              base + suffix,
              cookie,
            )
            assert_eq(allowed.code, 200)
          }
        }
        let (outsider, _) = @web_testkit.http_get_path_with_cookie(
          port, base, bob,
        )
        assert_eq(outsider.code, 404)
        pool.with_client(client => {
          ignore(
            client.execute(
              "INSERT INTO team_member(team_id,user_id,role) VALUES(1,2,'member')",
            ),
          )
        })
        for suffix in ["", "/visibility", "/delete"] {
          let (ordinary, _) = @web_testkit.http_get_path_with_cookie(
            port,
            base + suffix,
            bob,
          )
          assert_eq(ordinary.code, 403)
        }
        pool.with_client(client => {
          ignore(
            client.execute(
              "UPDATE team_member SET role='admin' WHERE team_id=1 AND user_id=2",
            ),
          )
        })
        let token = danger_form_token(port, bob, "visibility")
        let (changed, _) = @web_testkit.http_post_path_with_cookie(
          port,
          base + "/visibility",
          "csrf_token=\{token}&repository_id=1&previous=private&visibility=public",
          bob,
        )
        assert_eq(changed.code, 303)
        pool.with_client(client => {
          ignore(
            client.execute(
              "UPDATE team_member SET role='member' WHERE team_id=1 AND user_id=2",
            ),
          )
        })
        let (revoked, _) = @web_testkit.http_post_path_with_cookie(
          port,
          base + "/visibility",
          "csrf_token=\{token}&repository_id=1&previous=public&visibility=private",
          bob,
        )
        assert_eq(revoked.code, 403)
      },
      repo_root=root,
    )
  })
}

///|
async test "repository deletion validates names cascades data and rejects forms after same-name recreation" {
  @web_testkit.with_repository_test_app((port, pool, root, alice, _) => {
    let base = "/alice/demo/settings/danger-zone"
    let deletion = danger_form_token(port, alice, "delete")
    let visibility = danger_form_token(port, alice, "visibility")
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let key = @ssh.add_repository_deploy_key(
      pool,
      actor,
      repo,
      "Deletion test",
      @ssh.parse_ssh_public_key(@test_support.test_ssh_public_key),
    )
    for token in ["", visibility] {
      let (invalid, _) = @web_testkit.http_post_path_with_cookie(
        port,
        base + "/delete",
        "csrf_token=\{token}&repository_id=1&confirmation=alice%2Fdemo",
        alice,
      )
      assert_eq(invalid.code, 403)
    }
    let (wrong, body) = @web_testkit.http_post_path_with_cookie(
      port,
      base + "/delete",
      "csrf_token=\{deletion}&repository_id=1&confirmation=alice%2FDemo",
      alice,
    )
    assert_eq(wrong.code, 400)
    assert_true(body.contains("value=\"alice/Demo\""))
    assert_true(body.contains("Enter the full repository name exactly"))
    pool.with_client(client => {
      client.batch_execute(
        "INSERT INTO issue(repository_id,number,author_id,title) VALUES(1,1,1,'Deleted issue'); INSERT INTO merge_request(repository_id,number,author_id,title,source_branch,target_branch) VALUES(1,1,1,'Deleted pull request','feature','master'); INSERT INTO branch_rule(repository_id,branch) VALUES(1,'master'); INSERT INTO attachment(id,repository_id,uploader_id,filename,media_type,byte_size,sha256) VALUES('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,1,'test.txt','application/octet-stream',3,'digest');",
      )
    })
    let (deleted, _) = @web_testkit.http_post_path_with_cookie(
      port,
      base + "/delete",
      "csrf_token=\{deletion}&repository_id=1&confirmation=alice%2Fdemo",
      alice,
    )
    assert_eq(deleted.code, 303)
    assert_eq(deleted.headers.get("location"), Some("/alice"))
    for path in ["/alice/demo", base, base + "/delete", "/alice/demo/issues/1"] {
      let (missing, _) = @web_testkit.http_get_path_with_cookie(
        port, path, alice,
      )
      assert_eq(missing.code, 404)
    }
    pool.with_client(client => {
      for table in ["issue", "merge_request", "branch_rule", "attachment"] {
        assert_true(client.query_all("SELECT * FROM \{table}").is_empty())
      }
      let revoked = client.query_one(
        "SELECT repository_id,revoked_at FROM repository_deploy_key WHERE id=?",
        params=[key],
      )
      assert_true((revoked.get_name("repository_id") : Int64?) is None)
      assert_true((revoked.get_name("revoked_at") : String?) is Some(_))
      assert_eq(
        client.query_all("SELECT * FROM attachment_file_garbage").length(),
        1,
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
    @repository.cleanup_deleted_repositories(pool, root)
    @repository.create_managed_repository(pool, root, repo, "private", false)
    for
      (action, token, extra) in [
        ("delete", deletion, "confirmation=alice%2Fdemo"),
        ("visibility", visibility, "previous=private&visibility=public"),
      ] {
      let (stale, _) = @web_testkit.http_post_path_with_cookie(
        port,
        base + "/" + action,
        "csrf_token=\{token}&repository_id=1&\{extra}",
        alice,
      )
      assert_eq(stale.code, 403)
    }
    assert_eq(
      @repository.repository_settings(pool, actor, repo).visibility,
      "private",
    )
  })
}

///|
async test "busy repository deletion retains the confirmation page and name" {
  @web_testkit.with_repository_test_app((port, pool, _, alice, _) => {
    let token = danger_form_token(port, alice, "delete")
    pool.with_client(client => {
      client.batch_execute(
        "INSERT INTO repository_mirror(repository_id,creator_id,url,active,force_push,prune,status) VALUES(1,1,'git@example.test:repo',1,0,0,'syncing');",
      )
    })
    let (busy, body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/settings/danger-zone/delete",
      "csrf_token=\{token}&repository_id=1&confirmation=alice%2Fdemo",
      alice,
    )
    assert_eq(busy.code, 400)
    assert_true(body.contains("A mirror is syncing"))
    assert_true(body.contains("value=\"alice/demo\""))
    assert_true(body.contains("Delete this repository"))
  })
}
