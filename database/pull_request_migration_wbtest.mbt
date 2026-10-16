///|
async test "pull request upgrade preserves old checks and records their execution approval" {
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
          #|INSERT INTO merge_request(id, repository_id, number, author_id, title, source_branch, target_branch, current_version) VALUES (1, 1, 1, 1, 'Existing', 'source', 'main', 1);
          #|INSERT INTO merge_revision(merge_request_id, version, source_sha, target_sha, base_sha, merge_tree, block_reason) VALUES (1, 1, 'source', 'target', 'base', 'tree', '');
          #|INSERT INTO merge_check(merge_request_id, version, generation, workflow_path, requested_by_user_id, state, conclusion) VALUES (1, 1, 1, '.github/workflows/build.yml', 1, 'completed', 'success');
          #|PRAGMA user_version = 16;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let check = client.query_one("SELECT * FROM merge_check")
      assert_false((check.get_name("automatic") : Bool))
      assert_eq((check.get_name("conclusion") : String), "success")
      let approval = client.query_one("SELECT * FROM merge_execution_approval")
      assert_eq((approval.get_name("source_sha") : String), "source")
      assert_eq((approval.get_name("user_id") : Int64), 1L)
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
