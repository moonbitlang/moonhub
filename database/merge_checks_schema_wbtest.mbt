///|
async test "baseline defaults MR checks and protects immutable pipeline snapshots" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash) VALUES (1, 'test', 'Test', 'hash');
          #|INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'test', 'Test', 'personal');
          #|INSERT INTO repository (id, team_id, name) VALUES (1, 1, 'repo');
          #|INSERT INTO branch_rule(repository_id,branch,required_approvals) VALUES (1, 'main', 1);
          #|INSERT INTO merge_request (id, repository_id, number, author_id, title, source_branch, target_branch, current_version) VALUES (1, 1, 1, 1, 'Existing', 'feature', 'main', 1);
          #|INSERT INTO merge_revision (merge_request_id, version, source_sha, target_sha, base_sha) VALUES (1, 1, 'source', 'target', 'base');
          #|INSERT INTO pipeline_run (repository_id, number, requested_by_user_id, workflow_path, workflow_name, source_branch, commit_sha, source_ref, definition_version, workflow_source, definition_json) VALUES (1, 1, 1, '.github/workflows/build.yml', 'Existing', 'main', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'refs/moonhub/pipelines/existing', 1, 'existing workflow', '{}');
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT required_approvals FROM branch_rule")
          .get_name("required_approvals") : Int64),
        1L,
      )
      assert_true(
        client.query_all("SELECT * FROM branch_required_check").is_empty(),
      )
      assert_true(
        (
          client
          .query_one("SELECT merge_check_id FROM pipeline_run")
          .get_name("merge_check_id") : Int64?)
        is None,
      )
      assert_eq(
        (
          client
          .query_one("SELECT check_generation FROM merge_request")
          .get_name("check_generation") : Int64),
        1L,
      )
      client.batch_execute(
        (
          #|INSERT INTO branch_required_check VALUES (1, 'main', '.github/workflows/build.yml');
          #|INSERT INTO merge_check (id, merge_request_id, version, generation, workflow_path) VALUES (1, 1, 1, 1, '.github/workflows/build.yml');
          #|INSERT INTO pipeline_run (repository_id, number, requested_by_user_id, workflow_path, workflow_name, source_branch, commit_sha, source_ref, definition_version, workflow_source, definition_json, merge_check_id) VALUES (1, 2, 1, '.github/workflows/build.yml', 'MR check', 'feature', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'refs/moonhub/pipelines/mr-1', 1, 'target workflow', '{}', 1);
          #|UPDATE merge_check SET run_number = 2, state = 'queued' WHERE id = 1;
          #|UPDATE pipeline_run SET status = 'running' WHERE number = 2;
        ),
      )
      assert_eq(
        (
          client.query_one("SELECT state FROM merge_check").get_name("state") :
          String),
        "running",
      )
      ignore(
        client.execute(
          "UPDATE pipeline_run SET status = 'completed', conclusion = 'failure' WHERE number = 2",
        ),
      )
      assert_eq(
        (
          client
          .query_one("SELECT conclusion FROM merge_check")
          .get_name("conclusion") : String),
        "failure",
      )
      for
        sql in [
          "UPDATE merge_check SET version = 2", "UPDATE merge_check SET generation = 2",
          "UPDATE merge_check SET workflow_path = 'other'", "UPDATE pipeline_run SET merge_check_id = NULL WHERE number = 2",
          "UPDATE pipeline_run SET workflow_source = 'changed' WHERE number = 2",
          "INSERT INTO merge_check (merge_request_id, version, generation, workflow_path) VALUES (1, 1, 1, '.github/workflows/build.yml')",
        ] {
        try client.execute(sql) catch {
          @moondb.QueryError(_) => ()
          err => raise err
        } noraise {
          _ => fail("check identity constraint bypassed: " + sql)
        }
      }
      ignore(client.execute("DELETE FROM branch_rule"))
      assert_true(
        client.query_all("SELECT * FROM branch_required_check").is_empty(),
      )
      assert_eq(client.query_all("SELECT * FROM merge_check").length(), 1)
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
