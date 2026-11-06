///|
async test "self approval migration preserves branch rules and defaults to disabled" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        "DROP TABLE pipeline_job_output; ALTER TABLE merge_revision DROP COLUMN target_branch; DROP TABLE pipeline_cache; DROP TABLE pipeline_cache_scope; DROP TABLE pipeline_artifact_capability; DROP TABLE pipeline_artifact_block; DROP TABLE pipeline_artifact; DROP TABLE pipeline_artifact_runtime; DROP TABLE pipeline_run_schedule; DROP INDEX pipeline_matrix_active; ALTER TABLE pipeline_job DROP COLUMN matrix_fail_fast; ALTER TABLE pipeline_job DROP COLUMN max_parallel; ALTER TABLE pipeline_job DROP COLUMN matrix_group; ALTER TABLE branch_rule DROP COLUMN allow_self_approval; INSERT INTO branch_rule (repository_id, branch, required_approvals) VALUES (1, 'main', 1); INSERT INTO branch_required_check (repository_id, branch, workflow_path) VALUES (1, 'main', '.github/workflows/check.yml'); PRAGMA user_version = 29;",
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let rule = client.query_one(
        "SELECT required_approvals, allow_self_approval FROM branch_rule WHERE repository_id = 1 AND branch = 'main'",
      )
      assert_eq((rule.get_name("required_approvals") : Int64), 1L)
      assert_false((rule.get_name("allow_self_approval") : Bool))
      assert_eq(
        (
          client
          .query_one("SELECT workflow_path FROM branch_required_check")
          .get_name("workflow_path") : String),
        ".github/workflows/check.yml",
      )
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
      try
        client.execute("UPDATE branch_rule SET allow_self_approval = 2")
      catch {
        @moondb.QueryError(_) => ()
        err => raise err
      } noraise {
        _ => fail("invalid self approval policy accepted")
      }
      ignore(client.execute("UPDATE branch_rule SET allow_self_approval = 1"))
    })
    initialize_db(pool)
    pool.with_client(client => {
      assert_true(
        (
          client
          .query_one("SELECT allow_self_approval FROM branch_rule")
          .get_name("allow_self_approval") : Bool),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
