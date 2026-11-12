///|
async test "baseline disables push workflows by default" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash) VALUES (1, 'test', 'Test', 'hash');
          #|INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'test', 'Test', 'personal');
          #|INSERT INTO repository (id, team_id, name, visibility) VALUES (1, 1, 'repo', 'private');
          #|INSERT INTO pipeline_run (id, repository_id, number, requested_by_user_id, workflow_path, workflow_name, source_branch, commit_sha, source_ref, definition_version, workflow_source, definition_json)
          #|VALUES (1, 1, 1, 1, '.github/workflows/test.yml', 'Old run', 'main', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'refs/moonhub/pipelines/old', 1, 'old source', '{}');
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_false(
        (
          client
          .query_one("SELECT pipeline_push_enabled FROM repository")
          .get_name("pipeline_push_enabled") : Bool),
      )
      let run = client.query_one("SELECT * FROM pipeline_run")
      assert_true((run.get_name("trigger_event_id") : Int64?) is None)
      assert_eq((run.get_name("workflow_source") : String), "old source")
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
