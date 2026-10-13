///|
async test "access token upgrade preserves accounts sessions and collaboration without creating credentials" {
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
        "db/migrations/015_notifications.sql",
      ] {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user"(id, name_key, display_name, password_hash) VALUES (1, 'alice', 'Alice', 'hash'), (2, 'bob', 'Bob', 'hash');
          #|INSERT INTO team(id, name_key, display_name, kind) VALUES (1, 'alice', 'Alice', 'personal');
          #|INSERT INTO repository(id, team_id, name) VALUES (1, 1, 'demo');
          #|INSERT INTO issue(id, repository_id, number, author_id, assignee_id, title) VALUES (1, 1, 1, 1, 2, 'Existing');
          #|INSERT INTO issue_activity(issue_id, actor_id, kind) VALUES (1, 1, 'opened');
          #|INSERT INTO merge_request(id, repository_id, number, author_id, title, source_branch, target_branch) VALUES (1, 1, 1, 1, 'MR', 'source', 'main');
          #|INSERT INTO merge_activity(merge_request_id, actor_id, kind) VALUES (1, 2, 'comment');
          #|INSERT INTO email_outbox(to_email, subject, body) VALUES ('alice@example.com', 'Existing mail', 'Existing body');
          #|PRAGMA user_version = 15;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_true(client.query_all("SELECT * FROM access_token").is_empty())
      assert_eq(
        (
          client.query_one("SELECT COUNT(*) AS n FROM \"user\"").get_name("n") :
          Int64),
        2L,
      )
      assert_eq(
        (client.query_one("SELECT title FROM issue").get_name("title") : String),
        "Existing",
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
