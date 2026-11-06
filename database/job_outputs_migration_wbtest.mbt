///|
async test "job output schema upgrades version 34 without changing completed runs" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|DROP TABLE pipeline_job_output;
          #|PRAGMA user_version=34;
          #|INSERT INTO "user"(id,name_key,display_name,password_hash) VALUES(1,'legacy','Legacy','hash');
          #|INSERT INTO team(id,name_key,display_name,kind) VALUES(1,'legacy','Legacy','personal');
          #|INSERT INTO repository(id,team_id,name,visibility) VALUES(1,1,'repo','private');
          #|INSERT INTO pipeline_run(id,repository_id,number,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,source_ref,definition_version,workflow_source,definition_json,status,conclusion) VALUES(1,1,1,1,'.github/workflows/ci.yml','Old','main','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/moonhub/pipelines/old',3,'source','{}','completed','success');
          #|INSERT INTO pipeline_job(id,run_id,job_key,ordinal,status,conclusion) VALUES(1,1,'build',0,'completed','success');
          #|INSERT INTO pipeline_job_attempt(id,job_id,number,status,conclusion,result_hash,finished_at) VALUES(1,1,1,'completed','success','old-hash','2026-11-06');
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
      let run = client.query_one("SELECT * FROM pipeline_run WHERE id=1")
      assert_eq((run.get_name("status") : String), "completed")
      assert_eq((run.get_name("definition_version") : Int64), 3L)
      assert_eq(
        (
          client
          .query_one("SELECT result_hash FROM pipeline_job_attempt WHERE id=1")
          .get_name("result_hash") : String),
        "old-hash",
      )
      assert_true(
        client.query_all("SELECT * FROM pipeline_job_output").is_empty(),
      )
      ignore(
        client.execute(
          "INSERT INTO pipeline_job_output(job_id,attempt_id,outputs_json) VALUES(1,1,'{}')",
        ),
      )
      ignore(client.execute("DELETE FROM pipeline_run WHERE id=1"))
      assert_true(
        client.query_all("SELECT * FROM pipeline_job_output").is_empty(),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
