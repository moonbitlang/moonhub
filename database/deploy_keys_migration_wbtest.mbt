///|
async test "deploy key migration preserves user keys and protects credential identities" {
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
      ] {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash) VALUES (1, 'test', 'Test', 'hash');
          #|INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'test', 'Test', 'personal');
          #|INSERT INTO repository (id, team_id, name) VALUES (1, 1, 'repo'), (2, 1, 'other');
          #|INSERT INTO ssh_key (user_id, title, public_key, fingerprint) VALUES (1, 'existing', 'user-key', 'user-fingerprint');
          #|PRAGMA user_version = 12;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let row = client.query_one("SELECT * FROM ssh_key")
      assert_eq((row.get_name("title") : String), "existing")
      assert_true((row.get_name("revoked_at") : String?) is None)
      ignore(
        client.execute(
          "INSERT INTO repository_deploy_key (repository_id, title, public_key, fingerprint, creator_id) VALUES (1, 'deploy', 'deploy-key', 'deploy-fingerprint', 1)",
        ),
      )
      assert_false(
        (
          client
          .query_one("SELECT write_access FROM repository_deploy_key")
          .get_name("write_access") : Bool),
      )
      for
        sql in [
          "INSERT INTO repository_deploy_key (repository_id, title, public_key, fingerprint, creator_id) VALUES (2, 'duplicate', 'deploy-key', 'deploy-fingerprint', 1)",
          "INSERT INTO repository_deploy_key (repository_id, title, public_key, fingerprint, creator_id) VALUES (1, 'collision', 'user-key', 'user-fingerprint', 1)",
          "INSERT INTO ssh_key (user_id, title, public_key, fingerprint) VALUES (1, 'collision', 'deploy-key', 'deploy-fingerprint')",
          "UPDATE ssh_key SET public_key = 'deploy-key'", "UPDATE repository_deploy_key SET repository_id = 2",
          "UPDATE repository_deploy_key SET fingerprint = 'changed'", "UPDATE repository_deploy_key SET public_key = 'changed'",
        ] {
        try client.execute(sql) catch {
          @moondb.QueryError(_) => ()
          err => raise err
        } noraise {
          _ => fail("credential identity constraint was bypassed")
        }
      }
      ignore(client.execute("DELETE FROM repository WHERE id = 1"))
      let key = client.query_one("SELECT * FROM repository_deploy_key")
      assert_true((key.get_name("repository_id") : Int64?) is None)
      assert_true((key.get_name("revoked_at") : String?) is Some(_))
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
