///|
async test "pipeline migration upgrades schema six and is safe to initialize twice" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    for
      file in [
        "db/base.sql", "db/migrations/001_ssh_keys.sql", "db/migrations/002_repository_jobs.sql",
        "db/migrations/003_ssh_addresses.sql", "db/migrations/004_merge_requests.sql",
        "db/migrations/005_mail_settings.sql", "db/migrations/006_personal_namespaces.sql",
      ] {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }
    pool.with_client(client => {
      client.batch_execute(
        "INSERT INTO \"user\" (id, name_key, display_name, password_hash) VALUES (1, 'existing', 'Existing', 'hash');\n" +
        "INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'existing', 'Existing', 'personal');\n" +
        "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 1, 'owner');\n" +
        "INSERT INTO repository (id, team_id, name, ready) VALUES (1, 1, 'repo', 1);\n" +
        "INSERT INTO repository_job (repository_id, requested_by_user_id, status) VALUES (1, 1, 'succeeded');\n" +
        "PRAGMA user_version = 6;",
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let version : Int64 = client
        .query_one("PRAGMA user_version")
        .get_name("user_version")
      assert_eq(version, 7L)
      assert_eq(client.query_all("SELECT id FROM repository").length(), 1)
      let status : String = client
        .query_one("SELECT status FROM repository_job")
        .get_name("status")
      assert_eq(status, "succeeded")
      assert_true(client.query_all("SELECT id FROM pipeline_run").is_empty())
      assert_true(client.query_all("SELECT id FROM pipeline_job").is_empty())
      assert_true(
        client.query_all("SELECT id FROM pipeline_job_attempt").is_empty(),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
