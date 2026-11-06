///|
async test "mirror key upgrade pauses existing mirrors and preserves sync history" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        "DROP TABLE pipeline_job_output; ALTER TABLE merge_revision DROP COLUMN target_branch; DROP TABLE pipeline_cache; DROP TABLE pipeline_cache_scope; DROP TABLE pipeline_artifact_capability; DROP TABLE pipeline_artifact_block; DROP TABLE pipeline_artifact; DROP TABLE pipeline_artifact_runtime; DROP TABLE pipeline_run_schedule; DROP INDEX pipeline_matrix_active; ALTER TABLE pipeline_job DROP COLUMN matrix_fail_fast; ALTER TABLE pipeline_job DROP COLUMN max_parallel; ALTER TABLE pipeline_job DROP COLUMN matrix_group; ALTER TABLE branch_rule DROP COLUMN allow_self_approval; DROP TABLE mirror_host_check; ALTER TABLE repository_mirror DROP COLUMN host_keys; DROP TABLE mirror_ssh_key; PRAGMA user_version=26;" +
        "INSERT INTO repository_mirror(id,repository_id,creator_id,url,active,force_push,prune,status,version,generation) VALUES(1,1,1,'git@source.example:org/demo.git',1,0,0,'syncing',4,8);" +
        "INSERT INTO mirror_attempt(mirror_id,generation,status) VALUES(1,8,'succeeded');",
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let row = client.query_one(
        "SELECT active,status,version,generation FROM repository_mirror WHERE id=1",
      )
      assert_false((row.get_name("active") : Bool))
      assert_eq((row.get_name("status") : String), "disabled")
      assert_eq((row.get_name("version") : Int64), 5L)
      assert_eq((row.get_name("generation") : Int64), 9L)
      assert_true(client.query_all("SELECT * FROM mirror_ssh_key").is_empty())
      assert_eq(client.query_all("SELECT * FROM mirror_attempt").length(), 1)
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
