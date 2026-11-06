///|
async test "target migration backfills revision branch names without replaying activity" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|ALTER TABLE merge_revision DROP COLUMN target_branch;
          #|INSERT INTO merge_request(id,repository_id,number,author_id,title,source_branch,target_branch,current_version) VALUES(1,1,1,1,'Legacy','feature','main',1);
          #|INSERT INTO merge_revision(merge_request_id,version,source_sha,target_sha,base_sha) VALUES(1,1,'source','target','base');
          #|INSERT INTO merge_activity(merge_request_id,actor_id,kind,version) VALUES(1,1,'opened',1);
          #|PRAGMA user_version=33;
        ),
      )
    })
    let before : Int64 = pool.with_client(client => {
      client
      .query_one("SELECT COUNT(*) AS count FROM collaboration_event")
      .get_name("count")
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT target_branch FROM merge_revision")
          .get_name("target_branch") : String),
        "main",
      )
      assert_eq(
        (
          client
          .query_one("SELECT COUNT(*) AS count FROM collaboration_event")
          .get_name("count") : Int64),
        before,
      )
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
