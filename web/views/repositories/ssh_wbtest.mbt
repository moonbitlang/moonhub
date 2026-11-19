///|
async test "production browser hides unregistered and unauthorized repositories" {
  @web_testkit.with_production_test_app((_, port, pool) => {
    let key = @identity.hash_password("sshBrowserPassword")
    pool.with_client(client => {
      let _ = client.execute(
        "INSERT INTO \"user\" (name_key, display_name, password_hash) VALUES ('ssh_browser', 'Browser', ?)",
        params=[key],
      )
      let _ = client.execute(
        "INSERT INTO team (name_key, display_name, kind) VALUES ('alice', 'Alice', 'personal')",
      )
      let _ = client.execute(
        "INSERT INTO repository (team_id, name, visibility) SELECT id, 'demo', 'private' FROM team WHERE name_key = 'alice'",
      )
    })
    let cookie = @web_testkit.login_test_user(
      port, "ssh_browser", "sshBrowserPassword",
    )
    let (index_response, index) = @web_testkit.http_get_path_with_cookie(
      port, "/", cookie,
    )
    assert_eq(index_response.code, 200)
    assert_true(!index.contains("alice/demo"))
    let (denied, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(denied.code, 404)
    pool.with_client(client => {
      let _ = client.execute("UPDATE repository SET visibility = 'public'")
    })
    let (allowed, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(allowed.code, 200)
    pool.with_client(client => {
      let _ = client.execute("DELETE FROM repository")
    })
    let (unregistered, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(unregistered.code, 404)
  })
}

///|
async test "unborn repositories show first-push guidance according to SSH access and write permission" {
  let root = @fs.tmpdir(prefix="moonhub-empty-")
  defer @fs.rmdir(root, recursive=true)
  @web_testkit.with_ssh_settings_app(
    (port, pool, alice, bob, _) => {
      let repo : @domain.RepoId = { owner: "alice", name: "empty", }
      let git_dir = repo.git_dir(root)
      let path = "/alice/empty"
      @repository.create_managed_repository(pool, root, repo, "public", false)
      let (files, body) = @web_testkit.http_get_path_with_cookie(
        port, path, alice,
      )
      assert_eq(files.code, 200)
      assert_true(
        body.contains("Contact a site administrator to set up SSH access"),
      )
      assert_true(!body.contains("git push --"))
      assert_true(body.contains("class=\"repo-clone\""))
      assert_true(body.contains("class=\"commit-history\""))
      assert_true(body.contains("<strong>0</strong> commits"))
      assert_true(body.contains("aria-label=\"Releases\""))
      assert_true(!body.contains("branch-picker"))
      assert_true(!body.contains("Go to file"))
      assert_true(!body.contains("file-table"))
      let (commits, body) = @web_testkit.http_get_path_with_cookie(
        port,
        path + "/commits",
        alice,
      )
      assert_eq(commits.code, 200)
      assert_true(body.contains("No commits."))
      for invalid in [path + "?rev=missing", path + "/tree/missing"] {
        assert_eq(
          @web_testkit.http_get_path_with_cookie(port, invalid, alice).0.code,
          404,
        )
      }
      let admin = @identity.active_user_by_name(pool, "admin")
      @repository.save_ssh_endpoint(
        pool, admin, @repository.no_ssh_address_config, "git.example.com", "12222",
      )
      let url = "ssh://git@git.example.com:12222/alice/empty.git"
      for
        (response, body) in [
          @web_testkit.http_get_path(port, path),
          @web_testkit.http_get_path_with_cookie(port, path, bob),
        ] {
        assert_eq(response.code, 200)
        assert_true(body.contains("Waiting for the first commit."))
        assert_true(body.contains(url))
        assert_true(!body.contains("git push --"))
        assert_true(!body.contains("Contact a site administrator"))
      }
      ignore(
        @gitops.run_git(git_dir, ["symbolic-ref", "HEAD", "refs/tags/unborn"]),
      )
      let (fallback, body) = @web_testkit.http_get_path_with_cookie(
        port, path, alice,
      )
      assert_eq(fallback.code, 200)
      assert_true(
        body.contains("This command pushes your current local branch."),
      )
      assert_true(body.contains("git push -- &#39;\{url}&#39; &#39;HEAD&#39;"))

      let branch = "topic/it's-ready"
      let branch_ref = "refs/heads/\{branch}"
      ignore(@gitops.run_git(git_dir, ["symbolic-ref", "HEAD", branch_ref]))
      pool.with_client(client => {
        ignore(
          client.execute(
            "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
          ),
        )
      })
      let (writer, body) = @web_testkit.http_get_path_with_cookie(
        port, path, bob,
      )
      assert_eq(writer.code, 200)
      assert_true(
        body.contains("<a href=\"/-/settings/ssh-keys\">SSH keys</a>"),
      )
      assert_true(
        body.contains(
          "git push -- &#39;\{url}&#39; &#39;HEAD:refs/heads/topic/it&#39;\\&#39;&#39;s-ready&#39;",
        ),
      )
      ignore(
        @gitops.run_git("\{@web_testkit.test_repo_root}/alice/demo.git", [
          "push",
          "--",
          git_dir,
          "HEAD:\{branch_ref}",
        ]),
      )
      let (first_push, body) = @web_testkit.http_get_path_with_cookie(
        port, path, bob,
      )
      assert_eq(first_push.code, 200)
      assert_true(body.contains("README.md"))
      assert_true(body.contains("branch-picker"))
      assert_true(body.contains("Go to file"))
      assert_true(!body.contains("repository-first-push"))
      assert_true(body.contains("<strong>1</strong> commit"))

      let tree = @gitops.merge_git(git_dir, ["mktree"]).trim().to_owned()
      let commit = @gitops.run_git(git_dir, [
          "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit-tree",
          tree, "-p", "HEAD", "-m", "Empty file tree",
        ])
        .trim()
        .to_owned()
      ignore(@gitops.run_git(git_dir, ["update-ref", branch_ref, commit]))
      let (empty_tree, body) = @web_testkit.http_get_path_with_cookie(
        port, path, bob,
      )
      assert_eq(empty_tree.code, 200)
      assert_true(body.contains("No files."))
      assert_true(body.contains("Go to file"))
      assert_true(!body.contains("repository-first-push"))
      assert_true(body.contains("<strong>2</strong> commits"))
    },
    repo_root=root,
  )
}

///|
async test "dangling defaults preserve repository pages without changing HEAD" {
  @web_testkit.with_repository_test_app((port, _, root, cookie, _) => {
    let git_dir = root + "/alice/demo.git"
    let sha = @gitops.run_git(git_dir, ["rev-parse", "master"])
      .trim()
      .to_owned()
    ignore(
      @gitops.run_git(git_dir, [
        "update-ref", "refs/heads/feature/selfhost", sha,
      ]),
    )
    ignore(@gitops.run_git(git_dir, ["update-ref", "-d", "refs/heads/master"]))
    ignore(
      @gitops.run_git(git_dir, ["symbolic-ref", "HEAD", "refs/heads/main"]),
    )
    for route in ["/alice/demo", "/alice/demo/tree", "/alice/demo/commits"] {
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port, route, cookie,
      )
      assert_eq(response.code, 200, msg=body)
      assert_true(body.contains("feature/selfhost"))
      assert_true(
        body.contains(
          if route.has_suffix("commits") {
            "initial fixture commit"
          } else {
            "README.md"
          },
        ),
      )
    }
    let (file, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/blob/feature/selfhost/README.md", cookie,
    )
    assert_eq(file.code, 200)
    assert_true(body.contains("hello fixture moonhub"))
    for
      route in [
        "/alice/demo?rev=missing", "/alice/demo/tree/missing", "/alice/demo/commits?rev=missing",
      ] {
      assert_eq(
        @web_testkit.http_get_path_with_cookie(port, route, cookie).0.code,
        404,
      )
    }
    assert_eq(@gitops.default_ref(git_dir), "main")
    // Retention refs alone are not an alternative public branch.
    ignore(
      @gitops.run_git(git_dir, [
        "update-ref", "refs/moonhub/pipelines/private", sha,
      ]),
    )
    ignore(
      @gitops.run_git(git_dir, [
        "update-ref", "-d", "refs/heads/feature/selfhost",
      ]),
    )
    let (files, files_body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", cookie,
    )
    assert_eq(files.code, 200)
    assert_true(files_body.contains("This repository is empty"))
    let (commits, commits_body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/commits", cookie,
    )
    assert_eq(commits.code, 200)
    assert_true(commits_body.contains("No commits."))
  })
}
