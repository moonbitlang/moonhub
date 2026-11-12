///|
async test "baseline keeps missing run context explicit and immutable" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user"(id, name_key, display_name, password_hash) VALUES (1, 'alice', 'Alice', 'hash');
          #|INSERT INTO team(id, name_key, display_name, kind) VALUES (1, 'alice', 'Alice', 'personal');
          #|INSERT INTO repository(id, team_id, name) VALUES (1, 1, 'demo');
          #|INSERT INTO pipeline_run(id, repository_id, number, requested_by_user_id, workflow_path, workflow_name, source_branch, commit_sha, source_ref, definition_version, workflow_source, definition_json)
          #|VALUES (1, 1, 1, 1, '.github/workflows/build.yml', 'Legacy', 'master', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'refs/moonhub/pipelines/legacy', 1, 'original source', '{"name":"Legacy","jobs":[]}');
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
