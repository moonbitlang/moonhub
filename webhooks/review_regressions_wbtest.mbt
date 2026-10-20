///|
async test "informational responses preserve final status across response boundaries" {
  for
    (chunks, expected) in [
      (
        [
          "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </app.css>\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n",
        ],
        204,
      ),
      (
        [
          "HTTP/1.1 103 Early Hints\r\n\r", "\nHTTP/1.1 2", "00 OK\r\nContent-Length: 0\r",
          "\n\r\n",
        ],
        200,
      ),
      (
        ["HTTP/1.1 103 Early Hints\r\n\r\n", "HTTP/1.1 503 Unavailable\r\n\r\n"],
        503,
      ),
      (["HTTP/1.0 204 No Content\r\n\r\n" + "x".repeat(40000)], 204),
    ] {
    let reader = @io.MemoryReader(writer => {
      for chunk in chunks {
        writer.write(chunk)
        @async.pause()
      }
    })
    defer reader.close()
    assert_eq(read_response_status(reader), expected)
  }
}

///|
async test "informational responses retain cumulative limits and reject invalid completion" {
  for
    response in [
      "HTTP/1.1 101 Switching Protocols\r\n\r\n",
      "HTTP/1.1 103 Early Hints\r\n\r\n",
      "HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 204 No Content\r\n",
      "HTTP/1.1 2x4 No Content\r\n\r\n",
      ("HTTP/1.1 103 Early Hints\r\nX-Padding: " +
      "a".repeat(17000) +
      "\r\n\r\n").repeat(2) +
      "HTTP/1.1 204 No Content\r\n\r\n",
    ] {
    let reader = @io.MemoryReader(writer => writer.write(response))
    defer reader.close()
    try ignore(read_response_status(reader)) catch {
      Rejected => ()
      err => raise err
    } noraise {
      _ => fail("invalid or oversized response accepted")
    }
  }
  let reader = @io.MemoryReader(writer => {
    writer.write("HTTP/1.1 103 Early Hints\r\n\r\n")
    @async.sleep(1000)
  })
  defer reader.close()
  try
    ignore(
      @async.with_timeout(
        20,
        () => read_response_status(reader),
        error=Rejected,
      ),
    )
  catch {
    Rejected => ()
    err => raise err
  } noraise {
    _ => fail("interim response bypassed request deadline")
  }
}

///|
async test "delivery records final success after actual informational HTTP response" {
  @test_support.with_ssh_test_db(pool => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let origin = "http://127.0.0.1:\{server.addr.port()}"
      group.spawn_bg(no_wait=true, () => {
        let (conn, _) = server.accept()
        defer conn.close()
        ignore(conn.read_some(max_len=4096))
        @io.Writer::write(
          conn, "HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n",
        )
      })
      let actor = @identity.active_user_by_name(pool, "alice")
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let policy = Policy::new(allowed_origins=[origin])
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
      ping(pool, actor, repo, id)
      assert_true(deliver_next(pool, policy))
      let delivery = deliveries(pool, actor, repo, id)[0]
      assert_eq(delivery.response_code, 204L)
      assert_eq(delivery.status, "succeeded")
      assert_eq(delivery.attempts, 1L)
    })
  })
}

///|
async test "failed recovery page advances to healthy repository and wraps fairly" {
  @test_support.with_repository_test_data((pool, root) => {
    let dir = "\{root}/alice/demo.git"
    let sha = @gitops.branch_sha(dir, "master")
    ignore(
      @gitops.merge_git(dir, [
        "update-ref", "refs/tags/recovery-regression", sha,
      ]),
    )
    pool.with_client(client => {
      for i in 101..<=121 {
        let id = i.to_int64()
        ignore(
          client.execute(
            "INSERT INTO repository(id,team_id,name) VALUES(?,1,?)",
            params=[id, "unavailable" + id.to_string()],
          ),
        )
        ignore(
          client.execute(
            "INSERT INTO webhook_ref_intent(repository_id,actor_id,source_key,reference,old_sha,new_sha,state) VALUES(?,1,?,'refs/tags/recovery-regression',?,?,'prepared')",
            params=[id, id.to_string().pad_start(32, '0'), "0".repeat(40), sha],
          ),
        )
      }
      ignore(client.execute("UPDATE repository SET name='original' WHERE id=1"))
      ignore(client.execute("UPDATE repository SET name='demo' WHERE id=121"))
    })
    let cursor = recover_refs(pool, root)
    assert_eq(cursor, 120L)
    let cursor = recover_refs(pool, root, after=cursor)
    assert_eq(cursor, 121L)
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one(
            "SELECT state FROM webhook_ref_intent WHERE repository_id=121",
          )
          .get_name("state") : String),
        "ready",
      )
      assert_eq(
        (
          client
          .query_one("SELECT COUNT(*) AS count FROM webhook_event")
          .get_name("count") : Int64),
        1L,
      )
    })
    let cursor = recover_refs(pool, root, after=cursor)
    assert_eq(cursor, 0L)
    // Previously failed repositories are revisited after the scan wraps.
    pool.with_client(client => {
      ignore(
        client.execute("UPDATE repository SET name='finished' WHERE id=121"),
      )
      ignore(client.execute("UPDATE repository SET name='demo' WHERE id=101"))
    })
    assert_eq(recover_refs(pool, root, after=cursor), 120L)
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one(
            "SELECT state FROM webhook_ref_intent WHERE repository_id=101",
          )
          .get_name("state") : String),
        "ready",
      )
      assert_eq(
        (
          client
          .query_one("SELECT COUNT(*) AS count FROM webhook_event")
          .get_name("count") : Int64),
        2L,
      )
    })
    assert_eq(recover_refs(pool, root, after=121L), 0L)
  })
}

///|
async test "manual redelivery restarts backoff while retaining cumulative attempt history" {
  @test_support.with_ssh_test_db(pool => {
    @async.with_task_group(group => {
      let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      let origin = "http://127.0.0.1:\{server.addr.port()}"
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
      let mut code = 503
      group.spawn_bg(no_wait=true, () => {
        server.run_forever((_, body, conn) => {
          ignore(body.read_all())
          conn.send_response(code, "Fixture", extra_headers={
            "Content-Length": "0",
          })
          conn.end_response()
        })
      })
      ping(pool, actor, repo, id)
      let delivery = deliveries(pool, actor, repo, id)[0].id
      for cycle in 0..<2 {
        if cycle > 0 {
          redeliver(pool, actor, repo, id, delivery)
        }
        for step in 0..<5 {
          pool.with_client(client => {
            ignore(
              client.execute(
                "UPDATE webhook_delivery SET next_attempt_at=datetime('now') WHERE id=?",
                params=[delivery],
              ),
            )
          })
          assert_true(deliver_next(pool, policy))
          let result = deliveries(pool, actor, repo, id)[0]
          assert_eq(result.id, delivery)
          assert_eq(result.attempts, (cycle * 5 + step + 1).to_int64())
          assert_eq(result.status, if step == 4 { "failed" } else { "pending" })
          if step < 4 {
            pool.with_client(client => {
              let seconds : Int64 = client
                .query_one(
                  "SELECT CAST(strftime('%s',d.next_attempt_at) AS INTEGER)-CAST(strftime('%s',a.completed_at) AS INTEGER) AS seconds FROM webhook_delivery d JOIN webhook_attempt a ON a.delivery_id=d.id AND a.attempt=d.attempts WHERE d.id=?",
                  params=[delivery],
                )
                .get_name("seconds")
              assert_eq(seconds, [10L, 60L, 300L, 1800L][step])
            })
          }
        }
      }
      redeliver(pool, actor, repo, id, delivery)
      code = 204
      assert_true(deliver_next(pool, policy))
      assert_eq(deliveries(pool, actor, repo, id)[0].attempts, 11L)
      assert_eq(deliveries(pool, actor, repo, id)[0].status, "succeeded")
      redeliver(pool, actor, repo, id, delivery)
      code = 503
      assert_true(deliver_next(pool, policy))
      pool.with_client(client => {
        let row = client.query_one(
          "SELECT attempts,max_attempts,CAST(strftime('%s',d.next_attempt_at) AS INTEGER)-CAST(strftime('%s',a.completed_at) AS INTEGER) AS seconds FROM webhook_delivery d JOIN webhook_attempt a ON a.delivery_id=d.id AND a.attempt=d.attempts WHERE d.id=?",
          params=[delivery],
        )
        assert_eq((row.get_name("attempts") : Int64), 12L)
        assert_eq((row.get_name("max_attempts") : Int64), 16L)
        assert_eq((row.get_name("seconds") : Int64), 10L)
      })
      assert_true(
        delivery_detail(pool, actor, repo, id, delivery)
        is { "attempts": Array(items), .. } &&
        items.length() == 12,
      )
    })
  })
}
