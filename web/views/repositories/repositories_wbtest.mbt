///|
async test "team owners create private repositories without exposing partially prepared data" {
  @web_testkit.with_repository_test_app((port, pool, root, alice_cookie, _) => {
    let csrf = @web_testkit.repository_test_token(port, "alice", alice_cookie)
    let (response, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/-/repositories",
      "csrf_token=\{csrf}&name=new-repo&visibility=private&team=bob",
      alice_cookie,
    )
    assert_eq(response.code, 303)
    assert_true(
      response.headers.get("location")
      is Some("/alice/-/repositories/new-repo/status"),
    )
    let alice = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "new-repo", }
    assert_true(!@fs.exists(repo.git_dir(root)))
    assert_true(
      !@repository.can_access_repository(pool, alice, repo, @repository.Read),
    )
    let (pending, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/-/repositories/new-repo/status", alice_cookie,
    )
    assert_eq(pending.code, 200)
    assert_true(pending.headers.get("refresh") is Some("2"))
    assert_true(@repository.run_next_repository_job(pool, root, None))
    assert_true(
      @repository.can_access_repository(pool, alice, repo, @repository.Write),
    )
    assert_eq(@gitops.default_ref(repo.git_dir(root)), "main")
    let (ready, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/-/repositories/new-repo/status", alice_cookie,
    )
    assert_eq(ready.code, 303)
    assert_true(ready.headers.get("location") is Some("/alice/new-repo"))
    let (team_response, team_body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice", alice_cookie,
    )
    assert_eq(team_response.code, 200)
    assert_true(team_body.contains("New repository"))
    assert_true(team_body.contains("/alice/new-repo"))
    assert_true(!@repository.run_next_repository_job(pool, root, None))
  })
}

///|
async test "team repository creation denies outsiders ordinary members and forged CSRF tokens" {
  @web_testkit.with_repository_test_app((port, pool, _, alice, bob) => {
    let csrf = @web_testkit.repository_test_token(port, "alice", alice)
    let (outsider, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/-/repositories",
      "csrf_token=\{csrf}&name=stolen",
      bob,
    )
    assert_eq(outsider.code, 403)
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
      )
    })
    let (member_response, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/-/repositories/new", bob,
    )
    assert_eq(member_response.code, 403)
    let (missing, _) = @web_testkit.http_post_path_with_cookie(
      port, "/alice/-/repositories", "name=invalid", alice,
    )
    assert_eq(missing.code, 403)
    let settings_csrf = @web_testkit.settings_form_token(port, alice)
    let (wrong_scope, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/-/repositories",
      "csrf_token=\{settings_csrf}&name=invalid",
      alice,
    )
    assert_eq(wrong_scope.code, 403)
    let (unconfigured, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/-/repositories/import",
      "csrf_token=\{csrf}&name=imported&source_url=git@source.example:repo.git",
      alice,
    )
    assert_eq(unconfigured.code, 400)
  })
}

///|
async test "concurrent creation reserves a name once and never reinitializes existing data" {
  @web_testkit.with_repository_test_app((port, pool, root, alice, _) => {
    let csrf = @web_testkit.repository_test_token(port, "alice", alice)
    let results = @async.all([
      () => {
        @web_testkit.http_post_path_with_cookie(
          port,
          "/alice/-/repositories",
          "csrf_token=\{csrf}&name=unique",
          alice,
        )
      },
      () => {
        @web_testkit.http_post_path_with_cookie(
          port,
          "/alice/-/repositories",
          "csrf_token=\{csrf}&name=unique",
          alice,
        )
      },
    ])
    assert_true(
      (results[0].0.code == 303 && results[1].0.code == 400) ||
      (results[1].0.code == 303 && results[0].0.code == 400),
    )
    let head = @fs.read_file("\{root}/alice/demo.git/HEAD").text()
    let (duplicate, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/-/repositories",
      "csrf_token=\{csrf}&name=demo",
      alice,
    )
    assert_eq(duplicate.code, 400)
    assert_eq(@fs.read_file("\{root}/alice/demo.git/HEAD").text(), head)
    assert_true(@repository.run_next_repository_job(pool, root, None))
    assert_true(!@repository.run_next_repository_job(pool, root, None))
  })
}

///|
async test "failed jobs can be discarded and permissions are rechecked before execution" {
  @web_testkit.with_repository_test_app((port, pool, root, alice_cookie, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
    let repo = @repository.enqueue_repository(
      pool, root, alice, team, "failed", "private", "",
    )
    pool.with_client(client => {
      let _ = client.execute(
        "DELETE FROM team_member WHERE team_id = 1 AND user_id = 1",
      )
    })
    assert_true(@repository.run_next_repository_job(pool, root, None))
    assert_eq(
      @repository.require_repository_job(pool, team, repo.name).status,
      "failed",
    )
    assert_true(!@fs.exists(repo.git_dir(root)))
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 1, 'owner')",
      )
    })
    let (confirmation, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/-/repositories/failed/discard", alice_cookie,
    )
    assert_eq(confirmation.code, 200)
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let (discarded, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/-/repositories/failed/discard",
      "csrf_token=\{csrf}",
      alice_cookie,
    )
    assert_eq(discarded.code, 303)
    ignore(
      @repository.enqueue_repository(
        pool, root, alice, team, "failed", "private", "",
      ),
    )
    assert_true(@repository.run_next_repository_job(pool, root, None))
  })
}
