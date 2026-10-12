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
