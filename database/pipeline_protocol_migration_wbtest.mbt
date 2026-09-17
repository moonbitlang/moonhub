///|
async test "protocol migration preserves schema seven runs and backfills runner labels" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    for
      file in [
        "db/base.sql", "db/migrations/001_ssh_keys.sql", "db/migrations/002_repository_jobs.sql",
        "db/migrations/003_ssh_addresses.sql", "db/migrations/004_merge_requests.sql",
        "db/migrations/005_mail_settings.sql", "db/migrations/006_personal_namespaces.sql",
        "db/migrations/007_pipelines.sql",
      ] {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash) VALUES (1, 'alice', 'Alice', 'test');
          #|INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'alice', 'Alice', 'personal');
          #|INSERT INTO team_member (team_id, user_id, role) VALUES (1, 1, 'owner');
          #|INSERT INTO repository (id, team_id, name) VALUES (1, 1, 'demo');
          #|INSERT INTO pipeline_run(id, repository_id, number, requested_by_user_id, workflow_path, workflow_name,
          #|  source_branch, commit_sha, source_ref, definition_version, workflow_source, definition_json)
          #|VALUES (1, 1, 1, 1, '.github/workflows/build.yml', 'Build', 'main',
          #|  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'refs/moonhub/pipelines/test', 1, 'original',
          #|  '{"name":"Build","jobs":[{"id":"build","runs_on":["self-hosted","linux"]},{"id":"test","runs_on":["self-hosted","arm64"]}]}');
          #|INSERT INTO pipeline_job(id, run_id, job_key, ordinal, status) VALUES (1, 1, 'build', 0, 'running'), (2, 1, 'test', 1, 'waiting');
          #|INSERT INTO pipeline_job_need(run_id, job_key, needs_job_key) VALUES (1, 'test', 'build');
          #|INSERT INTO pipeline_job_attempt(job_id, number, status) VALUES (1, 1, 'running');
          #|PRAGMA user_version = 7;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT workflow_source FROM pipeline_run")
          .get_name("workflow_source") : String),
        "original",
      )
      assert_eq(client.query_all("SELECT * FROM pipeline_job_need").length(), 1)
      assert_eq(
        client.query_all("SELECT * FROM pipeline_job_label").length(),
        4,
      )
      assert_eq(
        (
          client
          .query_one(
            "SELECT COUNT(*) AS n FROM pipeline_job_label WHERE job_id = 1 AND label = 'linux'",
          )
          .get_name("n") : Int64),
        1L,
      )
      assert_eq(
        (
          client
          .query_one(
            "SELECT COUNT(*) AS n FROM pipeline_job_label WHERE job_id = 2 AND label = 'arm64'",
          )
          .get_name("n") : Int64),
        1L,
      )
      assert_true(
        (
          client
          .query_one("SELECT provider_id FROM pipeline_job_attempt")
          .get_name("provider_id") : Int64?)
        is None,
      )
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
