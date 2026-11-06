///|
async test "repository secret migration upgrades schema 28 without changing repositories and is idempotent" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        "DROP TABLE pipeline_job_output; DROP TABLE pipeline_cache; DROP TABLE pipeline_cache_scope; DROP TABLE pipeline_artifact_capability; DROP TABLE pipeline_artifact_block; DROP TABLE pipeline_artifact; DROP TABLE pipeline_artifact_runtime; DROP TABLE pipeline_run_schedule; DROP INDEX pipeline_matrix_active; ALTER TABLE pipeline_job DROP COLUMN matrix_fail_fast; ALTER TABLE pipeline_job DROP COLUMN max_parallel; ALTER TABLE pipeline_job DROP COLUMN matrix_group; ALTER TABLE branch_rule DROP COLUMN allow_self_approval; DROP TABLE pipeline_secret_delivery; DROP TABLE repository_secret; PRAGMA user_version = 28;",
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_true(
        client.query_all("SELECT * FROM repository_secret").is_empty(),
      )
      assert_true(
        client.query_all("SELECT * FROM pipeline_secret_delivery").is_empty(),
      )
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
      assert_true(
        client.query_opt("SELECT id FROM repository WHERE id = 1") is Some(_),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
