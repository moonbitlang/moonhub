///|
async test "repository API creates through namespace authorization and reports provisioning" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let read = @identity.create_access_token(pool, alice, "read", "read", 1)
    let write = @identity.create_access_token(pool, alice, "write", "write", 1)
    let bob_write = @identity.create_access_token(pool, bob, "bob", "write", 1)
    let bob_read = @identity.create_access_token(
      pool, bob, "bob-read", "read", 1,
    )
    let request : Json = { "owner": "alice", "name": "hello-moon" }
    let (anonymous, _) = api_test_request(port, "/repos", "", Some(request))
    assert_eq(anonymous, 401)
    let (read_only, _) = api_test_request(port, "/repos", read, Some(request))
    assert_eq(read_only, 403)
    let (outsider, _) = api_test_request(
      port,
      "/repos",
      bob_write,
      Some(request),
    )
    assert_eq(outsider, 403)
    let (unknown_owner, _) = api_test_request(
      port,
      "/repos",
      write,
      Some({ "owner": "nobody", "name": "hello-moon" }),
    )
    assert_eq(unknown_owner, 404)
    let (bad_visibility, _) = api_test_request(
      port,
      "/repos",
      write,
      Some({ "owner": "alice", "name": "hello-moon", "visibility": "internal" }),
    )
    assert_eq(bad_visibility, 400)
    let (unknown_field, _) = api_test_request(
      port,
      "/repos",
      write,
      Some({ "owner": "alice", "name": "hello-moon", "source_url": "ssh://x/y" }),
    )
    assert_eq(unknown_field, 400)
    let (created, json) = api_test_request(port, "/repos", write, Some(request))
    assert_eq(created, 200)
    assert_true(
      json
      is {
        "full_name": String("alice/hello-moon"),
        "visibility": String("private"),
        "state": String("pending"),
        "default_branch": Null,
        "clone_url": Null,
        ..
      },
    )
    let (duplicate, _) = api_test_request(port, "/repos", write, Some(request))
    assert_eq(duplicate, 400)
    // A pending private repository is visible only to namespace managers.
    let (hidden, _) = api_test_request(
      port,
      "/repos/alice/hello-moon",
      bob_read,
      None,
    )
    assert_eq(hidden, 404)
    let (pending, json) = api_test_request(
      port,
      "/repos/alice/hello-moon",
      read,
      None,
    )
    assert_eq(pending, 200)
    assert_true(json is { "state": String("pending"), .. })
    pool.with_client(client => {
      ignore(client.execute("UPDATE repository_job SET status = 'running'"))
    })
    let (running, json) = api_test_request(
      port,
      "/repos/alice/hello-moon",
      read,
      None,
    )
    assert_eq(running, 200)
    assert_true(
      json is { "state": String("running"), "default_branch": Null, .. },
    )
    assert_true(@repository.run_next_repository_job(pool, root, None))
    let (ready, json) = api_test_request(
      port,
      "/repos/alice/hello-moon",
      read,
      None,
    )
    assert_eq(ready, 200)
    assert_true(
      json is { "state": String("ready"), "default_branch": String("main"), .. },
    )
    let (still_hidden, _) = api_test_request(
      port,
      "/repos/alice/hello-moon",
      bob_read,
      None,
    )
    assert_eq(still_hidden, 404)
    @repository.save_ssh_endpoint(
      pool,
      @identity.active_user_by_name(pool, "admin"),
      @repository.no_ssh_address_config,
      "git.example.test",
      "2222",
    )
    // Organization namespaces use the same owner/admin rule.
    let (org, json) = api_test_request(
      port,
      "/repos",
      write,
      Some({ "owner": "workshop", "name": "tools", "visibility": "public" }),
    )
    assert_eq(org, 200)
    assert_true(
      json
      is {
        "full_name": String("workshop/tools"),
        "visibility": String("public"),
        "clone_url": String(
          "ssh://git@git.example.test:2222/workshop/tools.git",
        ),
        ..
      },
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE repository_job SET status = 'failed' WHERE status = 'pending'",
        ),
      )
    })
    let (failed, json) = api_test_request(
      port,
      "/repos/workshop/tools",
      read,
      None,
    )
    assert_eq(failed, 200)
    assert_true(json is { "state": String("failed"), .. })
    assert_eq(
      api_test_request(port, "/repos/workshop/tools", bob_read, None).0,
      404,
    )
    let (squad, _) = api_test_request(
      port,
      "/repos",
      write,
      Some({ "owner": "squad", "name": "tools" }),
    )
    assert_eq(squad, 403)
    let (code, output) = @process.collect_output_merged("git", [
      "init",
      "--bare",
      "--initial-branch=main",
      "\{root}/alice/public.git",
    ])
    assert_eq(code, 0, msg=output.text())
    let (existing, json) = api_test_request(
      port,
      "/repos/alice/public",
      bob_read,
      None,
    )
    assert_eq(existing, 200)
    assert_true(
      json is { "state": String("ready"), "visibility": String("public"), .. },
    )
  })
}

///|
async test "repository metadata resolves literal names and reads the Git default branch" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let write = @identity.create_access_token(pool, alice, "write", "write", 1)
    let (invalid, _) = api_test_request(
      port,
      "/repos",
      write,
      Some({ "owner": "alice", "name": "../invalid" }),
    )
    assert_eq(invalid, 400)
    let (created, json) = api_test_request(
      port,
      "/repos",
      write,
      Some({ "owner": "alice", "name": "docs.git" }),
    )
    assert_eq(created, 200)
    assert_true(json is { "full_name": String("alice/docs.git"), .. })
    assert_true(@repository.run_next_repository_job(pool, root, None))
    let (ready, json) = api_test_request(
      port,
      "/repos/alice/docs.git",
      write,
      None,
    )
    assert_eq(ready, 200)
    assert_true(
      json is { "state": String("ready"), "default_branch": String("main"), .. },
    )
    let dir = "\{root}/alice/demo.git"
    ignore(
      @gitops.run_git(dir, ["symbolic-ref", "HEAD", "refs/heads/release/stable"]),
    )
    let (viewed, json) = api_test_request(
      port,
      "/repos/alice/demo",
      write,
      None,
    )
    assert_eq(viewed, 200)
    assert_true(json is { "default_branch": String("release/stable"), .. })
  })
}
