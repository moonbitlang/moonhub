///|
async test "password recovery migration upgrades version nine without losing users sessions or mail" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    for
      file in [
        "db/base.sql", "db/migrations/001_ssh_keys.sql", "db/migrations/002_repository_jobs.sql",
        "db/migrations/003_ssh_addresses.sql", "db/migrations/004_merge_requests.sql",
        "db/migrations/005_mail_settings.sql", "db/migrations/006_personal_namespaces.sql",
        "db/migrations/007_pipelines.sql", "db/migrations/008_pipeline_protocol.sql",
        "db/migrations/009_runner_steps.sql",
      ] {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, email, password_hash)
          #|VALUES (1, 'alice', 'Alice', 'alice@example.com', 'existing-password');
          #|INSERT INTO session (user_id, token_hash, expires_at)
          #|VALUES (1, 'existing-session', datetime('now', '+30 days'));
          #|INSERT INTO email_outbox (to_email, subject, body)
          #|VALUES ('alice@example.com', 'Existing email', 'Preserved body');
          #|PRAGMA user_version = 9;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT password_hash FROM \"user\"")
          .get_name("password_hash") : String),
        "existing-password",
      )
      assert_eq(
        (
          client
          .query_one("SELECT token_hash FROM session")
          .get_name("token_hash") : String),
        "existing-session",
      )
      let mail = client.query_one(
        "SELECT body, password_reset_id FROM email_outbox",
      )
      assert_eq((mail.get_name("body") : String), "Preserved body")
      assert_true((mail.get_name("password_reset_id") : Int64?) is None)
      assert_true(client.query_all("SELECT id FROM password_reset").is_empty())
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
    })
  })
}
