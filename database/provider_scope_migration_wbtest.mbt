///|
async test "provider scope migration preserves selected grants and never promotes existing providers" {
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
      ] {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'team', 'Team', 'org');
          #|INSERT INTO repository (id, team_id, name, visibility) VALUES (1, 1, 'repo', 'private');
          #|INSERT INTO pipeline_provider (id, name, token_hash, paused, revoked) VALUES (1, 'existing', 'hash', 1, 0), (2, 'revoked', 'other', 0, 1);
          #|INSERT INTO pipeline_provider_repository VALUES (1, 1);
          #|INSERT INTO pipeline_provider_label VALUES (1, 'linux'), (1, 'self-hosted');
          #|PRAGMA user_version = 10;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      for row in client.query_all("SELECT * FROM pipeline_provider") {
        assert_eq((row.get_name("repository_scope") : String), "selected")
        assert_true((row.get_name("last_seen_ms") : Int64?) is None)
      }
      let row = client.query_one("SELECT * FROM pipeline_provider WHERE id = 1")
      assert_eq((row.get_name("token_hash") : String), "hash")
      assert_true((row.get_name("paused") : Bool))
      assert_false((row.get_name("revoked") : Bool))
      assert_eq(
        client.query_all("SELECT * FROM pipeline_provider_repository").length(),
        1,
      )
      assert_eq(
        client.query_all("SELECT * FROM pipeline_provider_label").length(),
        2,
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
