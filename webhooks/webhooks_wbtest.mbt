///|
async test "webhook authorization subscriptions snapshots and stale configuration" {
  @test_support.with_ssh_test_db(pool => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let policy = Policy::new()
    let id = save_hook(
      pool,
      actor,
      repo,
      0L,
      0L,
      "https://example.com/hook",
      "0123456789abcdef",
      ["issue"],
      true,
      policy,
    )
    try ignore(list_hooks(pool, bob, repo)) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("outsider listed hooks")
    }
    pool.with_client(client => {
      client.batch_execute(
        "INSERT INTO team_member(team_id,user_id,role) VALUES(1,2,'member'); INSERT INTO issue(id,repository_id,number,author_id,title) VALUES(1,1,1,2,'Before'); INSERT INTO issue_activity(issue_id,actor_id,kind,body) VALUES(1,2,'comment','Hello 世界');",
      )
    })
    try ignore(list_hooks(pool, bob, repo)) catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("contributor managed hooks")
    }
    let rows = deliveries(pool, actor, repo, id)
    assert_eq(rows.length(), 1)
    pool.with_client(client => {
      ignore(client.execute("UPDATE issue SET title='After' WHERE id=1"))
    })
    let detail = delivery_detail(pool, actor, repo, id, rows[0].id)
    assert_true(
      detail is { "payload": String(value), .. } &&
      value.contains("Before") &&
      value.contains("Hello 世界"),
    )
    assert_false(detail.stringify().contains("0123456789abcdef"))
    ignore(
      save_hook(
        pool,
        actor,
        repo,
        id,
        1L,
        "https://example.com/new",
        "",
        ["push"],
        true,
        policy,
      ),
    )
    assert_eq(deliveries(pool, actor, repo, id)[0].status, "cancelled")
    try
      ignore(
        save_hook(
          pool,
          actor,
          repo,
          id,
          1L,
          "https://example.com/new",
          "",
          ["push"],
          true,
          policy,
        ),
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale edit accepted")
    }
    ping(pool, actor, repo, id)
    assert_eq(deliveries(pool, actor, repo, id)[0].kind, "ping")
    pool.with_client(client => {
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
test "HMAC SHA256 uses exact bytes and standard signature format" {
  assert_eq(
    signature("key", "The quick brown fox jumps over the lazy dog"),
    "sha256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
  )
  assert_true(signature("key", "世界") != signature("key", "世"))
}

///|
test "destination URL and private network policy" {
  for
    url in [
      "http://example.com/hook", "https://user@example.com/hook", "https://example.com/#fragment",
      "https://example.com/\r\ninjected", "https://example.com:0/hook", "https://example.com\\@127.0.0.1/hook",
      "https://[::1]/hook",
    ] {
    try ignore(parse_target(url, Policy::new())) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("unsafe URL accepted: " + url)
    }
  }
  assert_eq(
    parse_target("https://example.com/hook?x=1", Policy::new()).path,
    "/hook?x=1",
  )
  let policy = Policy::new(allowed_origins=["http://127.0.0.1:9000"])
  assert_true(
    parse_target("http://127.0.0.1:9000/hook", policy).private_allowed,
  )
  for
    ip in [
      "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.0.1", "169.254.169.254", "0.0.0.0",
      "100.64.0.1", "224.0.0.1", "198.18.0.1",
    ] {
    assert_false(public_address(@socket.Addr::parse(ip + ":443")))
  }
  assert_true(public_address(@socket.Addr::parse("8.8.8.8:443")))
}

///|
async test "signed HTTP delivery retry redelivery and redirect rejection" {
  @test_support.with_ssh_test_db(pool => {
    @async.with_task_group(group => {
      let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let port = server.addr.port()
      let origin = "http://127.0.0.1:\{port}"
      let policy = Policy::new(allowed_origins=[origin])
      let actor = @identity.active_user_by_name(pool, "alice")
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let id = save_hook(
        pool,
        actor,
        repo,
        0L,
        0L,
        origin + "/hook",
        "0123456789abcdef",
        ["push"],
        true,
        policy,
      )
      let seen : Array[String] = []
      let requests : Array[String] = []
      let mut response = 503
      group.spawn_bg(no_wait=true, () => {
        server.run_forever((req, body, conn) => {
          assert_eq(req.path, "/hook")
          let body = body.read_all().text()
          assert_eq(
            req.headers.get("X-MoonHub-Signature-256"),
            Some(signature("0123456789abcdef", body)),
          )
          assert_eq(req.headers.get("X-MoonHub-Event"), Some("ping"))
          assert_true(req.headers.get("X-MoonHub-Event-ID") is Some(_))
          seen.push(req.headers.get("X-MoonHub-Delivery").unwrap())
          requests.push(body)
          conn.send_response(response, "Fixture", extra_headers={
            "Content-Length": "0",
            "Location": "http://127.0.0.1:1/private",
          })
          conn.end_response()
        })
      })
      ping(pool, actor, repo, id)
      assert_true(deliver_next(pool, policy))
      assert_eq(deliveries(pool, actor, repo, id)[0].status, "pending")
      assert_eq(deliveries(pool, actor, repo, id)[0].response_code, 503L)
      assert_false(deliver_next(pool, policy))
      pool.with_client(client => {
        ignore(
          client.execute(
            "UPDATE webhook_delivery SET next_attempt_at=datetime('now')",
          ),
        )
      })
      response = 204
      assert_true(deliver_next(pool, policy))
      let delivery = deliveries(pool, actor, repo, id)[0]
      assert_eq(delivery.status, "succeeded")
      assert_eq(delivery.attempts, 2L)
      assert_eq(seen[0], seen[1])
      assert_eq(requests[0], requests[1])
      redeliver(pool, actor, repo, id, delivery.id)
      response = 302
      assert_true(deliver_next(pool, policy))
      assert_eq(deliveries(pool, actor, repo, id)[0].response_code, 302L)
      assert_eq(seen.length(), 3)
      let detail = delivery_detail(pool, actor, repo, id, delivery.id)
      assert_true(
        detail is { "attempts": Array(items), .. } && items.length() == 3,
      )
    })
  })
}

///|
async test "expired leases retry and revoked owners cancel without network" {
  @test_support.with_ssh_test_db(pool => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let id = save_hook(
      pool,
      actor,
      repo,
      0L,
      0L,
      "https://example.com/hook",
      "0123456789abcdef",
      ["push"],
      true,
      Policy::new(),
    )
    ping(pool, actor, repo, id)
    let first = claim(pool).unwrap()
    assert_true(claim(pool) is None)
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE webhook_delivery SET locked_at=datetime('now','-2 minutes')",
        ),
      )
    })
    let second = claim(pool).unwrap()
    assert_eq(first.id, second.id)
    assert_eq(second.attempt, 2L)
    assert_true(first.lease != second.lease)
    pool.with_client(client => {
      let row = client.query_one(
        "SELECT error FROM webhook_attempt WHERE attempt=1",
      )
      assert_eq((row.get_name("error") : String), "Delivery lease expired")
      ignore(
        client.execute(
          "UPDATE webhook_delivery SET locked_at=datetime('now','-2 minutes')",
        ),
      )
      ignore(client.execute("UPDATE \"user\" SET status='disabled' WHERE id=1"))
    })
    assert_true(claim(pool) is None)
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT status FROM webhook_delivery")
          .get_name("status") : String),
        "cancelled",
      )
    })
  })
}

///|
async test "push events include contributors tags deletes and crash recovery independently of CI" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let id = save_hook(
      pool,
      actor,
      repo,
      0L,
      0L,
      "https://example.com/hook",
      "0123456789abcdef",
      ["push"],
      true,
      Policy::new(),
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id,user_id,role) VALUES(1,2,'member')",
        ),
      )
    })
    let bob = @identity.active_user_by_name(pool, "bob")
    let sha = @gitops.branch_sha(repo.git_dir(root), "master")
    let zero = "0".repeat(40)
    for
      (index, reference, before, after) in [
        ("a", "refs/heads/new", zero, sha),
        ("b", "refs/tags/v1", zero, sha),
        ("c", "refs/heads/removed", sha, zero),
      ] {
      let updates = "\{before} \{after} \{reference}"
      @repository.record_received_transaction(
        pool,
        bob,
        repo,
        index.repeat(32),
        "prepared",
        updates,
      )
      @repository.record_received_transaction(
        pool,
        bob,
        repo,
        index.repeat(32),
        "committed",
        updates,
      )
      @repository.record_received_transaction(
        pool,
        bob,
        repo,
        index.repeat(32),
        "committed",
        updates,
      )
    }
    assert_eq(deliveries(pool, actor, repo, id).length(), 3)
    assert_true(
      @test_support.ref_events(
        pool,
        @repository.repository_scope(pool, actor, repo),
      ).is_empty(),
    )
    @repository.record_received_transaction(
      pool,
      bob,
      repo,
      "d".repeat(32),
      "prepared",
      "\{zero} \{sha} refs/tags/recovered",
    )
    ignore(
      @gitops.merge_git(repo.git_dir(root), [
        "update-ref", "refs/tags/recovered", sha,
      ]),
    )
    @repository.with_repository_write(pool, root, actor, repo, (_, _) => ())
    assert_eq(deliveries(pool, actor, repo, id).length(), 4)
    @repository.record_received_transaction(
      pool,
      bob,
      repo,
      "e".repeat(32),
      "prepared",
      "\{zero} \{sha} refs/tags/aborted",
    )
    @repository.record_received_transaction(
      pool,
      bob,
      repo,
      "e".repeat(32),
      "aborted",
      "\{zero} \{sha} refs/tags/aborted",
    )
    assert_eq(deliveries(pool, actor, repo, id).length(), 4)
  })
}

///|
async test "MR discussion reviews merge pushes and pipeline completion emit transaction-local events" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let id = save_hook(
      pool,
      actor,
      repo,
      0L,
      0L,
      "https://example.com/hook",
      "0123456789abcdef",
      ["push", "merge_request", "review", "workflow_run"],
      true,
      Policy::new(),
    )
    let dir = repo.git_dir(root)
    let base = @gitops.branch_sha(dir, "master")
    let head = @test_support.merge_test_commit(
      dir, "feature", base, "webhook\n",
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, dir, actor, "Webhook MR", "Body", "feature", "master", false,
    )
    let opened = deliveries(pool, actor, repo, id)[0]
    assert_true(
      delivery_detail(pool, actor, repo, id, opened.id)
      is { "payload": String(value), .. } &&
      value.contains(head) &&
      value.contains("opened"),
    )
    @collaboration.submit_merge_review(
      pool,
      admin,
      mr,
      mr.version,
      "approved",
      "Reviewed",
    )
    assert_eq(deliveries(pool, actor, repo, id)[0].kind, "review")
    let prepared = @collaboration.prepare_anchored_merge_discussion(
      pool,
      scope,
      actor,
      mr,
      dir,
      1L,
      None,
      "README.md",
      "new",
      1L,
      1L,
      "Inline body",
    )
    let discussion = @collaboration.create_prepared_merge_discussion(
      pool, scope, actor, mr, prepared,
    )
    ignore(
      @collaboration.reply_merge_discussion(
        pool, scope, actor, mr, discussion, "Reply body",
      ),
    )
    assert_true(
      delivery_detail(
        pool,
        actor,
        repo,
        id,
        deliveries(pool, actor, repo, id)[0].id,
      )
      is { "payload": String(value), .. } &&
      value.contains("Reply body") &&
      value.contains("discussion_id"),
    )
    @collaboration.enqueue_merge(pool, scope, actor, mr, mr.version)
    assert_true(@collaboration.run_next_merge_job(pool, root))
    let merged = @collaboration.require_merge_request(pool, scope, mr.number)
    assert_eq(merged.status, "merged")
    let pushes = deliveries(pool, actor, repo, id).filter(d => d.kind == "push")
    assert_eq(pushes.length(), 1)
    assert_true(
      delivery_detail(pool, actor, repo, id, pushes[0].id)
      is { "payload": String(value), .. } &&
      value.contains(merged.merged_sha) &&
      value.contains(base),
    )
    let sha = @test_support.workflow_commit(
      dir, @test_support.single_job_workflow,
    )
    let run = @pipeline.create_run(
      pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
    )
    @pipeline.Coordinator::new(pool).cancel_run(actor, repo, run.number)
    let events = deliveries(pool, actor, repo, id).filter(d => {
      d.kind == "workflow_run"
    })
    assert_eq(events.length(), 2)
    assert_true(
      delivery_detail(pool, actor, repo, id, events[0].id)
      is { "payload": String(value), .. } &&
      value.contains("completed") &&
      value.contains("cancelled") &&
      value.contains(sha),
    )
  })
}

///|
async test "deploy key pushes retain machine identity and never authorize CI" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let id = save_hook(
      pool,
      actor,
      repo,
      0L,
      0L,
      "https://example.com/hook",
      "0123456789abcdef",
      ["push"],
      true,
      Policy::new(),
    )
    let key = @ssh.add_repository_deploy_key(
      pool,
      actor,
      repo,
      "Machine",
      @ssh.parse_ssh_public_key(@test_support.test_ssh_public_key),
      write_access=true,
    )
    let sha = @gitops.branch_sha(repo.git_dir(root), "master")
    let update = "\{"0".repeat(40)} \{sha} refs/tags/machine"
    @repository.record_deploy_key_webhook_transaction(
      pool,
      scope,
      key,
      "f".repeat(32),
      "prepared",
      update,
    )
    @repository.record_deploy_key_webhook_transaction(
      pool,
      scope,
      key,
      "f".repeat(32),
      "committed",
      update,
    )
    let rows = deliveries(pool, actor, repo, id)
    assert_eq(rows.length(), 1)
    assert_true(
      delivery_detail(pool, actor, repo, id, rows[0].id)
      is { "payload": String(value), .. } &&
      value.contains("deploy_key") &&
      !value.contains("username"),
    )
    assert_true(
      @test_support.ref_events(
        pool,
        @repository.repository_scope(pool, actor, repo),
      ).is_empty(),
    )
  })
}

///|
async test "rolled back business events never escape and changed hooks invalidate claimed work" {
  @test_support.with_ssh_test_db(pool => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let policy = Policy::new()
    let id = save_hook(
      pool,
      actor,
      repo,
      0L,
      0L,
      "https://example.com/hook",
      "0123456789abcdef",
      ["issue"],
      true,
      policy,
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO issue(id,repository_id,number,author_id,title) VALUES(1,1,1,1,'Rollback fixture')",
        ),
      )
    })
    try
      pool.with_client(client => {
        client.with_transaction(fn(tx) -> Unit raise {
          ignore(
            tx.execute(
              "INSERT INTO issue_activity(issue_id,actor_id,kind,body) VALUES(1,1,'comment','Never commit')",
            ),
          )
          raise @domain.BadRequest(message="rollback")
        })
      })
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("rollback fixture did not fail")
    }
    assert_true(deliveries(pool, actor, repo, id).is_empty())
    ping(pool, actor, repo, id)
    let assignment = claim(pool).unwrap()
    ensure_current_delivery(pool, assignment)
    ignore(
      save_hook(
        pool,
        actor,
        repo,
        id,
        1L,
        "https://example.com/changed",
        "",
        ["issue"],
        false,
        policy,
      ),
    )
    try ensure_current_delivery(pool, assignment) catch {
      Rejected => ()
      err => raise err
    } noraise {
      _ => fail("changed webhook retained sending authority")
    }
    assert_eq(deliveries(pool, actor, repo, id)[0].status, "cancelled")
  })
}
