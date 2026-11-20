///|
async test "repository secret pages protect forms preserve metadata and never echo saved or rejected values" {
  @web_testkit.with_repository_test_app((port, pool, _, alice, bob) => {
    let base = "/alice/demo/settings/secrets"
    let (empty, html) = @web_testkit.http_get_path_with_cookie(
      port, base, alice,
    )
    assert_eq(empty.code, 200)
    assert_true(html.contains("No repository secrets"))
    assert_eq(
      @web_testkit.http_get_path_with_cookie(port, base, bob).0.code,
      404,
    )
    let (_, form) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/new",
      alice,
    )
    let csrf = @web_testkit.extract_attr(
      form, "name=\"csrf_token\"", "value=\"",
    )
    let body = "name=TOKEN&value=page-private-value&branch=master&workflow=.github%2Fworkflows%2Fpublish.yml&version=0"
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, base, body, alice).0.code,
      403,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        base,
        body + "&csrf_token=" + csrf,
        alice,
      ).0.code,
      303,
    )
    let (_, listing) = @web_testkit.http_get_path_with_cookie(port, base, alice)
    assert_true(listing.contains("TOKEN"))
    assert_true(!listing.contains("page-private-value"))
    let (_, edit) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/TOKEN/edit",
      alice,
    )
    assert_true(!edit.contains("page-private-value"))
    assert_true(edit.contains("Leave blank to keep"))
    let version = @web_testkit.extract_attr(
      edit, "name=\"version\"", "value=\"",
    )
    let bad = "value=rejected-private-value&branch=master&workflow=invalid&version=" +
      version +
      "&csrf_token=" +
      csrf
    let (status, failed) = @web_testkit.http_post_path_with_cookie(
      port,
      base + "/TOKEN",
      bad,
      alice,
    )
    assert_eq(status.code, 400)
    assert_true(!failed.contains("rejected-private-value"))
    assert_true(failed.contains("value=\"master\""))
    let (_, deletion) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/TOKEN/delete",
      alice,
    )
    assert_true(deletion.contains("Future steps"))
    assert_true(!deletion.contains("page-private-value"))
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        base + "/TOKEN/delete",
        "version=" + version + "&csrf_token=" + csrf,
        alice,
      ).0.code,
      303,
    )
    assert_true(
      @pipeline.list_secrets(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        { owner: "alice", name: "demo", },
      ).is_empty(),
    )
  })
}

///|
async test "secret forms retain their original scope while an incomplete body outlives deletion or replacement" {
  for rebuild in [false, true] {
    let started = @async.Semaphore(1, initial_value=0)
    @web_testkit.with_repository_test_app(
      (port, pool, root, cookie, _) => {
        let actor = @identity.active_user_by_name(pool, "alice")
        let repo : @domain.RepoId = { owner: "alice", name: "demo", }
        let scope = @repository.repository_scope(pool, actor, repo)
        let base = "/alice/demo/settings/secrets"
        let (_, form) = @web_testkit.http_get_path_with_cookie(
          port,
          base + "/new",
          cookie,
        )
        let csrf = @web_testkit.extract_attr(
          form, "name=\"csrf_token\"", "value=\"",
        )
        let (response, body) = @web_testkit.partial_body_request(
          port,
          base,
          "name=TOKEN&value=delayed-form-private-value&branch=pipeline&workflow=.github%2Fworkflows%2Fbuild.yml&version=0&csrf_token=" +
          csrf,
          {
            "Content-Type": "application/x-www-form-urlencoded",
            "Cookie": "\{cookie.name}=\{cookie.value}",
          },
          started,
          () => {
            @repository.delete_repository(
              pool,
              root,
              actor,
              repo,
              scope.id,
              repo.path(),
            )
            @repository.cleanup_deleted_repositories(pool, root)
            assert_false(@fs.exists(repo.git_dir(root)))
            if rebuild {
              @repository.create_managed_repository(
                pool, root, repo, "private", false,
              )
              ignore(
                @test_support.workflow_commit(
                  repo.git_dir(root),
                  @test_support.single_job_workflow,
                ),
              )
              assert_true(
                @repository.repository_scope(pool, actor, repo).id != scope.id,
              )
            }
          },
        )
        assert_eq(response.code, if rebuild { 400 } else { 404 })
        assert_false(body.contains("delayed-form-private-value"))
        if rebuild {
          assert_true(body.contains("repository has changed"))
          assert_true(@pipeline.list_secrets(pool, actor, repo).is_empty())
        }
        pool.with_client(client => {
          assert_true(
            client.query_all("SELECT * FROM repository_secret").is_empty(),
          )
          assert_true(
            client
            .query_all(
              "SELECT * FROM repository_audit WHERE kind='secret_saved'",
            )
            .is_empty(),
          )
        })
      },
      body_read_started=started,
    )
  }
}
