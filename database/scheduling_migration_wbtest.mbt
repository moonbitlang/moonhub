///|
async test "workflow scheduling schema upgrades preserve old runs and migrate idempotently" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        31L,
      )
      assert_true(
        client.query_all("SELECT run_id FROM pipeline_run_schedule").is_empty(),
      )
      // Recreate schema 30's job columns without touching related tables; the
      // migration is applied on a genuinely old schema, not a fresh DB shortcut.
      client.batch_execute(
        "DROP TABLE pipeline_run_schedule; DROP INDEX pipeline_matrix_active; ALTER TABLE pipeline_job DROP COLUMN matrix_fail_fast; ALTER TABLE pipeline_job DROP COLUMN max_parallel; ALTER TABLE pipeline_job DROP COLUMN matrix_group; PRAGMA user_version=30;",
      )
    })
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user" (id,name_key,display_name,password_hash) VALUES (1,'legacy','Legacy','hash');
          #|INSERT INTO team (id,name_key,display_name,kind) VALUES (1,'legacy','Legacy','personal');
          #|INSERT INTO repository (id,team_id,name,visibility) VALUES (1,1,'repo','private');
          #|INSERT INTO pipeline_run (id,repository_id,number,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,source_ref,definition_version,workflow_source,definition_json) VALUES(1,1,1,1,'.github/workflows/check.yml','Legacy','main','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/moonhub/pipelines/old',2,'old source','{}');
          #|INSERT INTO pipeline_job(id,run_id,job_key,ordinal,status) VALUES(1,1,'build',0,'queued');
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
        31L,
      )
      let row = client.query_one(
        "SELECT matrix_group,max_parallel,matrix_fail_fast FROM pipeline_job WHERE id=1",
      )
      assert_eq((row.get_name("matrix_group") : String), "")
      assert_eq((row.get_name("max_parallel") : Int64), 256L)
      assert_false((row.get_name("matrix_fail_fast") : Bool))
      assert_true(
        client.query_all("SELECT run_id FROM pipeline_run_schedule").is_empty(),
      )
      assert_eq(
        (
          client
          .query_one("SELECT workflow_source FROM pipeline_run WHERE id=1")
          .get_name("workflow_source") : String),
        "old source",
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
