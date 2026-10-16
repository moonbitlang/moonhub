///|
async test "context migration preserves schema seventeen runs and keeps missing metadata explicit" {
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
        "db/migrations/017_pull_request_workflows.sql",
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
          #|INSERT INTO pipeline_run(id, repository_id, number, requested_by_user_id, workflow_path, workflow_name, source_branch, commit_sha, source_ref, definition_version, workflow_source, definition_json)
          #|VALUES (1, 1, 1, 1, '.github/workflows/build.yml', 'Legacy', 'master', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'refs/moonhub/pipelines/legacy', 1, 'original source', '{"name":"Legacy","jobs":[]}');
          #|PRAGMA user_version = 17;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let row = client.query_one("SELECT * FROM pipeline_run WHERE id = 1")
      assert_true((row.get_name("context_json") : String?) is None)
      assert_eq((row.get_name("workflow_source") : String), "original source")
      assert_eq(
        (row.get_name("definition_json") : String),
        "{\"name\":\"Legacy\",\"jobs\":[]}",
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
    let rejected = pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_run SET context_json = '{}' WHERE id = 1",
        ),
      )
      false
    }) catch {
      _ => true
    }
    assert_true(rejected)
  })
}
