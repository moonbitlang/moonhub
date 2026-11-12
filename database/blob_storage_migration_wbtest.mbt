///|
async test "blob storage migration preserves legacy rows and journals cascade deletion" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|DROP TRIGGER pipeline_artifact_storage_delete;
          #|DROP TABLE pipeline_blob_garbage;
          #|DROP TABLE pipeline_artifact_location;
          #|PRAGMA user_version=37;
          #|INSERT INTO pipeline_run(repository_id,number,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,source_ref,definition_version,workflow_source,definition_json)
          #|VALUES(1,1,(SELECT id FROM user LIMIT 1),'.github/workflows/build.yml','legacy','main','0000000000000000000000000000000000000000','refs/pipeline/legacy',1,'legacy','{}');
          #|INSERT INTO pipeline_job(run_id,job_key,ordinal,status) VALUES(1,'job',0,'queued');
          #|INSERT INTO pipeline_job_attempt(job_id,number,status) VALUES(1,1,'leased');
          #|INSERT INTO pipeline_artifact(repository_id,run_id,attempt_id,name,storage_key,state,size,digest,created_ms,expires_ms)
          #|VALUES(1,1,1,'legacy','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','ready',3,'legacy-digest',1,9999999999999);
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
      assert_true(
        client.query_all("SELECT * FROM pipeline_artifact_location").is_empty(),
      )
      assert_true(
        client.query_all("SELECT * FROM pipeline_blob_garbage").is_empty(),
      )
      let trigger = client.query_opt(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name='pipeline_artifact_storage_delete'",
      )
      assert_true(trigger is Some(_))
      assert_eq(
        (
          client
          .query_one("SELECT size FROM pipeline_artifact WHERE name='legacy'")
          .get_name("size") : Int64),
        3L,
      )
      ignore(client.execute("DELETE FROM pipeline_run WHERE id=1"))
      let intent = client.query_one(
        "SELECT location,key,kind FROM pipeline_blob_garbage",
      )
      assert_eq((intent.get_name("location") : String), "legacy-fs")
      assert_eq((intent.get_name("kind") : String), "namespace")
      assert_eq((intent.get_name("key") : String), "a".repeat(64))
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
