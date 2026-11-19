///|
async test "collaboration email rechecks permissions preferences addresses and subscriptions" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|UPDATE "user" SET email = 'admin@example.com' WHERE id = 3;
          #|INSERT INTO notification_preferences(user_id, email_enabled) VALUES (3, 1);
          #|INSERT INTO issue(repository_id, number, author_id, title) VALUES (1, 1, 1, 'Private issue');
          #|INSERT INTO notification_subscription(thread_id, user_id) SELECT id, 3 FROM collaboration_thread;
          #|INSERT INTO issue_activity(issue_id, actor_id, kind, body) VALUES (1, 1, 'comment', 'Secret reply');
        ),
      )
    })
    let first = claim_next_email(pool, "worker").unwrap()
    assert_eq(first.to_email, "admin@example.com")
    assert_true(first.body.contains("/alice/demo/issues/1"))
    assert_true(!first.body.contains("Secret reply"))
    mark_email_delivered(pool, first.id, "test")
    for revoked in ["preference", "subscription", "address", "permission"] {
      pool.with_client(client => {
        client.batch_execute(
          (
            #|UPDATE "user" SET is_site_admin = 1, email = 'admin@example.com' WHERE id = 3;
            #|UPDATE notification_preferences SET email_enabled = 1 WHERE user_id = 3;
            #|UPDATE notification_subscription SET subscribed = 1 WHERE user_id = 3;
            #|INSERT INTO issue_activity(issue_id, actor_id, kind, body) VALUES (1, 1, 'comment', 'Another reply');
          ),
        )
        ignore(
          client.execute(
            match revoked {
              "preference" =>
                "UPDATE notification_preferences SET email_enabled = 0 WHERE user_id = 3"
              "subscription" =>
                "UPDATE notification_subscription SET subscribed = 0 WHERE user_id = 3"
              "address" =>
                "UPDATE \"user\" SET email = 'other@example.com' WHERE id = 3"
              _ => "UPDATE \"user\" SET is_site_admin = 0 WHERE id = 3"
            },
          ),
        )
      })
      assert_true(claim_next_email(pool, "worker") is None, msg=revoked)
    }
  })
}

///|
async test "transfer pauses collaboration emails, blocks active sends, and retargets queued links" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    pool.with_client(client => {
      client.batch_execute(
        (
          #|UPDATE "user" SET email='admin@example.com' WHERE id=3;
          #|INSERT INTO notification_preferences(user_id,email_enabled) VALUES(3,1);
          #|INSERT INTO issue(repository_id,number,author_id,title) VALUES(1,1,1,'Moved issue');
          #|INSERT INTO notification_subscription(thread_id,user_id) SELECT id,3 FROM collaboration_thread;
          #|INSERT INTO issue_activity(issue_id,actor_id,kind,body) VALUES(1,1,'comment','A new reply');
        ),
      )
      client.batch_execute(
        "INSERT INTO repository_transfer(repository_id,target_team_id,name) VALUES(1,3,'demo'); UPDATE repository SET ready=0 WHERE id=1;",
      )
      assert_true(claim_next_email(pool, "worker") is None)
      let queued = client.query_one(
        "SELECT status,body,locked_by FROM email_outbox WHERE template='collaboration_notification'",
      )
      assert_eq((queued.get_name("status") : String), "pending")
      assert_true(
        (queued.get_name("body") : String).contains("/alice/demo/issues/1"),
      )
      assert_true((queued.get_name("locked_by") : String?) is None)
      client.batch_execute(
        "DELETE FROM repository_transfer WHERE repository_id=1; UPDATE repository SET ready=1 WHERE id=1;",
      )
    })
    let active = claim_next_email(pool, "worker").unwrap()
    try
      @repository.transfer_repository(
        pool,
        root,
        alice,
        { owner: "alice", name: "demo", },
        1L,
        3L,
        "alice/demo",
      )
    catch {
      @domain.BadRequest(message~) =>
        assert_true(message.contains("collaboration email is being sent"))
      err => raise err
    } noraise {
      _ => fail("transfer started while a collaboration email was being sent")
    }
    mark_email_failed(pool, active.id, "test lease release")
    let target = @repository.transfer_repository(
      pool,
      root,
      alice,
      { owner: "alice", name: "demo", },
      1L,
      3L,
      "alice/demo",
    )
    assert_eq(target.path(), "workshop/demo")
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE email_outbox SET next_attempt_at=datetime('now') WHERE template='collaboration_notification' AND status='pending'",
        ),
      )
    })
    let moved = claim_next_email(pool, "worker").unwrap()
    assert_true(moved.body.contains("/workshop/demo/issues/1"))
    assert_false(moved.body.contains("/alice/demo/issues/1"))
  })
}
