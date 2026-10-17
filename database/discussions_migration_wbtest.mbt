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
