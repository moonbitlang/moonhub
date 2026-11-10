///|
async test "OIDC schema upgrades version 36 preserves configuration and is idempotent" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|DROP TABLE pipeline_oidc_runtime;
          #|PRAGMA user_version=36;
          #|INSERT INTO repository_variable(repository_id,name,value) VALUES(1,'REGION','us-east-1');
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
          .query_one(
            "SELECT value FROM repository_variable WHERE name='REGION'",
          )
          .get_name("value") : String),
        "us-east-1",
      )
      assert_true(
        client.query_all("SELECT * FROM pipeline_oidc_runtime").is_empty(),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
