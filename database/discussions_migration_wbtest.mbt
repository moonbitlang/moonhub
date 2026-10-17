///|
async test "discussion migration preserves legacy comments tombstones reviews and notifications" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    for
      file in [
        "db/base.sql", "db/migrations/001_ssh_keys.sql", "db/migrations/002_repository_jobs.sql",
        "db/migrations/003_ssh_addresses.sql", "db/migrations/004_merge_requests.sql",
        "db/migrations/005_mail_settings.sql", "db/migrations/006_personal_namespaces.sql",
        "db/migrations/007_pipelines.sql", "db/migrations/008_pipeline_protocol.sql",
        "db/migrations/009_runner_steps.sql", "db/migrations/010_password_resets.sql",
        "db/migrations/011_provider_scope.sql", "db/migrations/012_pipeline_push.sql",
        "db/migrations/013_repository_deploy_keys.sql", "db/migrations/014_merge_checks.sql",
        "db/migrations/015_notifications.sql", "db/migrations/016_access_tokens.sql",
        "db/migrations/017_pull_request_workflows.sql", "db/migrations/018_run_context.sql",
      ] {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user"(id, name_key, display_name, password_hash) VALUES (1, 'alice', 'Alice', 'hash');
          #|INSERT INTO team(id, name_key, display_name, kind) VALUES (1, 'alice', 'Alice', 'personal');
          #|INSERT INTO repository(id, team_id, name) VALUES (1, 1, 'demo');
          #|INSERT INTO merge_request(id, repository_id, number, author_id, title, source_branch, target_branch, current_version) VALUES (1, 1, 1, 1, 'Existing', 'source', 'main', 2);
          #|INSERT INTO merge_activity(id, merge_request_id, actor_id, kind, body, version) VALUES (10, 1, 1, 'comment', 'Legacy body', 1), (11, 1, 1, 'comment_deleted', '', 1), (12, 1, 1, 'changes_requested', 'Fix this', 2), (13, 1, 1, 'approved', '', 2), (14, 1, 1, 'close', '', 2);
          #|PRAGMA user_version = 18;
        ),
      )
    })
    let events : Int64 = pool.with_client(client => {
      client
      .query_one("SELECT COUNT(*) AS count FROM collaboration_event")
      .get_name("count")
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let rows = client.query_all("SELECT * FROM merge_discussion ORDER BY id")
      assert_eq(rows.length(), 3)
      assert_eq((rows[0].get_name("id") : Int64), 10L)
      assert_eq((rows[0].get_name("version") : Int64), 1L)
      assert_false((rows[0].get_name("resolved") : Bool))
      assert_eq((rows[0].get_name("state_version") : Int64), 1L)
      assert_eq((rows[1].get_name("id") : Int64), 11L)
      let comment = client.query_one(
        "SELECT * FROM merge_activity WHERE id = 10",
      )
      assert_eq((comment.get_name("body") : String), "Legacy body")
      assert_eq((comment.get_name("discussion_id") : Int64), 10L)
      let legacy_event = client.query_one(
        "SELECT discussion_id, comment_id FROM collaboration_event WHERE event_key = 'merge-activity:10'",
      )
      assert_eq((legacy_event.get_name("discussion_id") : Int64), 10L)
      assert_eq((legacy_event.get_name("comment_id") : Int64), 10L)
      let deleted = client.query_one(
        "SELECT * FROM merge_activity WHERE id = 11",
      )
      assert_eq((deleted.get_name("body") : String), "")
      assert_eq((deleted.get_name("kind") : String), "comment_deleted")
      assert_eq(
        (
          client
          .query_one("SELECT COUNT(*) AS count FROM collaboration_event")
          .get_name("count") : Int64),
        events,
      )
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
      // Circular root membership must not break the pre-existing MR cascade.
      ignore(
        client.execute(
          "INSERT INTO merge_activity(merge_request_id, actor_id, kind, body, version, discussion_id) VALUES (1, 1, 'comment', 'Reply', 1, 10)",
        ),
      )
      ignore(client.execute("DELETE FROM merge_request WHERE id = 1"))
      assert_true(client.query_all("SELECT * FROM merge_discussion").is_empty())
      assert_true(client.query_all("SELECT * FROM merge_activity").is_empty())
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "discussion target upgrade backfills existing events without replaying delivery or read state" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    for
      file in [
        "db/base.sql", "db/migrations/001_ssh_keys.sql", "db/migrations/002_repository_jobs.sql",
        "db/migrations/003_ssh_addresses.sql", "db/migrations/004_merge_requests.sql",
        "db/migrations/005_mail_settings.sql", "db/migrations/006_personal_namespaces.sql",
        "db/migrations/007_pipelines.sql", "db/migrations/008_pipeline_protocol.sql",
        "db/migrations/009_runner_steps.sql", "db/migrations/010_password_resets.sql",
        "db/migrations/011_provider_scope.sql", "db/migrations/012_pipeline_push.sql",
        "db/migrations/013_repository_deploy_keys.sql", "db/migrations/014_merge_checks.sql",
        "db/migrations/015_notifications.sql", "db/migrations/016_access_tokens.sql",
        "db/migrations/017_pull_request_workflows.sql", "db/migrations/018_run_context.sql",
        "db/migrations/019_merge_discussions.sql",
      ] {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }

    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user"(id,name_key,display_name,password_hash,email) VALUES(1,'alice','Alice','hash','alice@example.invalid'),(2,'bob','Bob','hash','bob@example.invalid');
          #|INSERT INTO team(id,name_key,display_name,kind) VALUES(1,'alice','Alice','personal');
          #|INSERT INTO team_member(team_id,user_id,role) VALUES(1,1,'owner'),(1,2,'member');
          #|INSERT INTO repository(id,team_id,name) VALUES(1,1,'demo');
          #|INSERT INTO merge_request(id,repository_id,number,author_id,title,source_branch,target_branch,current_version) VALUES(1,1,1,1,'Upgrade','source','master',1);
          #|INSERT INTO notification_subscription(thread_id,user_id) SELECT id,1 FROM collaboration_thread WHERE merge_request_id=1;
          #|INSERT INTO notification_preferences(user_id,email_enabled) VALUES(1,1);
          #|INSERT INTO merge_activity(id,merge_request_id,actor_id,kind,body,version) VALUES(10,1,2,'comment','Existing root',1);
          #|INSERT INTO merge_activity(id,merge_request_id,actor_id,kind,body,version,discussion_id) VALUES(11,1,2,'comment','Existing reply',1,10);
          #|UPDATE merge_discussion SET resolved=1,state_version=2,state_actor_id=2 WHERE id=10;
          #|UPDATE collaboration_notification SET read_at='2026-10-17 00:00:00';
          #|PRAGMA user_version=19;
        ),
      )
    })
    let before : Array[(Int64, String)] = pool.with_client(client => {
      client
      .query_all(
        "SELECT id, read_at FROM collaboration_notification ORDER BY id",
      )
      .map(row => (row.get_name("id"), row.get_name("read_at")))
    })
    let mail : Int64 = pool.with_client(client => {
      client.query_one("SELECT COUNT(*) AS n FROM email_outbox").get_name("n")
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let after = client
        .query_all(
          "SELECT id, read_at FROM collaboration_notification ORDER BY id",
        )
        .map(row => {
          ((row.get_name("id") : Int64), (row.get_name("read_at") : String))
        })
      assert_eq(after, before)
      assert_eq(
        (
          client
          .query_one("SELECT COUNT(*) AS n FROM email_outbox")
          .get_name("n") : Int64),
        mail,
      )
      let reply = client.query_one(
        "SELECT discussion_id,comment_id FROM collaboration_event WHERE event_key='merge-activity:11'",
      )
      assert_eq((reply.get_name("discussion_id") : Int64), 10L)
      assert_eq((reply.get_name("comment_id") : Int64), 11L)
      let state = client.query_one(
        "SELECT discussion_id,comment_id FROM collaboration_event WHERE event_key='merge-discussion:10:2'",
      )
      assert_eq((state.get_name("discussion_id") : Int64), 10L)
      assert_eq((state.get_name("comment_id") : Int64?), None)
      ignore(
        client.execute(
          "INSERT INTO merge_activity(id,merge_request_id,actor_id,kind,body,version,discussion_id) VALUES(13,1,2,'comment','New reply',1,10)",
        ),
      )
      let email : String = client
        .query_one("SELECT body FROM email_outbox ORDER BY id DESC LIMIT 1")
        .get_name("body")
      assert_true(email.contains("?discussion=10&comment=13#comment-13"))
      ignore(
        client.execute(
          "UPDATE merge_discussion SET resolved=0,state_version=3,state_actor_id=2 WHERE id=10",
        ),
      )
      let state_email : String = client
        .query_one("SELECT body FROM email_outbox ORDER BY id DESC LIMIT 1")
        .get_name("body")
      assert_true(state_email.contains("?discussion=10#discussion-10"))
      ignore(client.execute("DELETE FROM merge_request WHERE id=1"))
      assert_true(
        client.query_all("SELECT * FROM collaboration_event").is_empty(),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
