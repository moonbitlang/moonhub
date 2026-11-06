///|
async test "cache schema upgrades version 32 without changing stored artifacts" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|DROP TABLE pipeline_job_output;
          #|DROP TABLE pipeline_cache;
          #|DROP TABLE pipeline_cache_scope;
          #|DROP INDEX pipeline_artifact_name;
          #|ALTER TABLE pipeline_artifact DROP COLUMN kind;
          #|CREATE UNIQUE INDEX pipeline_artifact_name ON pipeline_artifact(run_id,name) WHERE state <> 'deleted';
          #|PRAGMA user_version=32;
          #|INSERT INTO "user" (id,name_key,display_name,password_hash) VALUES(1,'legacy','Legacy','hash');
          #|INSERT INTO team(id,name_key,display_name,kind) VALUES(1,'legacy','Legacy','personal');
          #|INSERT INTO repository(id,team_id,name,visibility) VALUES(1,1,'repo','private');
          #|INSERT INTO pipeline_run(id,repository_id,number,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,source_ref,definition_version,workflow_source,definition_json) VALUES(1,1,1,1,'.github/workflows/ci.yml','Old','main','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','refs/moonhub/pipelines/old',2,'source','{}');
          #|INSERT INTO pipeline_job(id,run_id,job_key,ordinal,status) VALUES(1,1,'build',0,'queued');
          #|INSERT INTO pipeline_job_attempt(id,job_id,number,status) VALUES(1,1,1,'running');
          #|INSERT INTO pipeline_artifact(id,repository_id,run_id,attempt_id,name,storage_key,state,size,digest,created_ms,expires_ms) VALUES(1,1,1,1,'bundle','key','ready',7,'digest',1,999999);
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let row = client.query_one("SELECT * FROM pipeline_artifact WHERE id=1")
      assert_eq((row.get_name("kind") : String), "artifact")
      assert_eq((row.get_name("name") : String), "bundle")
      assert_eq((row.get_name("size") : Int64), 7L)
      assert_eq((row.get_name("digest") : String), "digest")
      assert_true(
        client.query_all("SELECT * FROM pipeline_cache_scope").is_empty(),
      )
      ignore(
        client.execute(
          "INSERT INTO pipeline_cache_scope VALUES(1,'refs/heads/main','','refs/heads/main')",
        ),
      )
      let immutable = try {
        ignore(
          client.execute(
            "UPDATE pipeline_cache_scope SET scope='refs/heads/other'",
          ),
        )
        false
      } catch {
        _ => true
      }
      assert_true(immutable)
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
