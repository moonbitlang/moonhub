///|
async test "runner control upgrade preserves providers and applies idempotently" {
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
        "db/migrations/019_merge_discussions.sql", "db/migrations/020_discussion_notification_targets.sql",
        "db/migrations/021_merge_discussion_anchors.sql", "db/migrations/022_attachments.sql",
        "db/migrations/023_general_attachments.sql", "db/migrations/024_webhooks.sql",
      ] {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }
    pool.with_client(client => {
      client.batch_execute(
        "INSERT INTO pipeline_provider(name,token_hash) VALUES('legacy','preserved-hash'); PRAGMA user_version=24;",
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let row = client.query_one(
        "SELECT token_hash,mode,config_revision,repository_scope FROM pipeline_provider WHERE name='legacy'",
      )
      assert_eq((row.get_name("token_hash") : String), "preserved-hash")
      assert_eq((row.get_name("mode") : String), "")
      assert_eq((row.get_name("config_revision") : Int64), 0L)
      assert_eq((row.get_name("repository_scope") : String), "selected")
      assert_true(client.query_all("SELECT * FROM pipeline_worker").is_empty())
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
