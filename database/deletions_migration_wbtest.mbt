///|
async test "repository deletion migration upgrades version 40, preserves storage and preferences and enforces durable name reservations" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|DROP TRIGGER repository_deletion_reservation;
          #|DROP TABLE repository_deletion_resource;
          #|DROP TABLE repository_deletion;
          #|INSERT INTO user_preferences(user_id,time_zone) VALUES(1,'Asia/Shanghai');
          #|INSERT INTO pipeline_blob_garbage(location,key,kind,not_before_ms) VALUES('legacy-fs','retained','namespace',1);
          #|PRAGMA user_version=40;
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
      assert_eq(
        (
          client
          .query_one("SELECT time_zone FROM user_preferences WHERE user_id=1")
          .get_name("time_zone") : String),
        "Asia/Shanghai",
      )
      assert_eq(
        (
          client
          .query_one("SELECT key FROM pipeline_blob_garbage")
          .get_name("key") : String),
        "retained",
      )
      ignore(
        client.execute(
          "INSERT INTO repository_deletion(repository_id,owner,name) VALUES(1,'alice','demo')",
        ),
      )
      ignore(
        client.execute(
          "INSERT INTO repository_deletion_resource(repository_id,kind,resource) VALUES(1,'attachment','manifest-id')",
        ),
      )
      ignore(client.execute("DELETE FROM repository WHERE id=1"))
      assert_eq(
        client.query_all("SELECT * FROM repository_deletion_resource").length(),
        1,
      )
      try
        client.execute("INSERT INTO repository(team_id,name) VALUES(1,'demo')")
      catch {
        @moondb.QueryError(_) => ()
        err => raise err
      } noraise {
        _ => fail("bypassed durable name reservation")
      }
      ignore(
        client.execute("DELETE FROM repository_deletion WHERE repository_id=1"),
      )
      ignore(
        client.execute("INSERT INTO repository(team_id,name) VALUES(1,'demo')"),
      )
      assert_true(
        client
        .query_all("SELECT * FROM repository_deletion_resource")
        .is_empty(),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
