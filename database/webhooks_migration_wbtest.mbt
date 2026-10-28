///|
async test "webhook migration preserves schema 23 history and never replays old events" {
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
        "db/migrations/023_general_attachments.sql",
      ] {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user"(id,name_key,display_name,password_hash) VALUES(1,'alice','Alice','hash');
          #|INSERT INTO team(id,name_key,display_name,kind) VALUES(1,'alice','Alice','personal');
          #|INSERT INTO repository(id,team_id,name) VALUES(1,1,'demo');
          #|INSERT INTO issue(id,repository_id,number,author_id,title) VALUES(1,1,1,1,'Existing');
          #|INSERT INTO issue_activity(issue_id,actor_id,kind,body) VALUES(1,1,'comment','Keep history');
          #|PRAGMA user_version=23;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
      assert_eq(
        (
          client.query_one("SELECT body FROM issue_activity").get_name("body") :
          String),
        "Keep history",
      )
      assert_true(client.query_all("SELECT id FROM webhook_event").is_empty())
      assert_true(
        client.query_all("SELECT id FROM repository_webhook").is_empty(),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
