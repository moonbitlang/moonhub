///|
async test "repository variable schema upgrades version 35 preserves existing data and is idempotent" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        (
          #|DROP TABLE repository_variable;
          #|PRAGMA user_version=35;
          #|INSERT INTO repository_secret(repository_id,name,value,branch,workflow_path) VALUES(1,'EXISTING_SECRET','private-value','main','.github/workflows/ci.yml');
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
        client.query_all("SELECT * FROM repository_variable").is_empty(),
      )
      assert_eq(
        (
          client
          .query_one(
            "SELECT value FROM repository_secret WHERE name='EXISTING_SECRET'",
          )
          .get_name("value") : String),
        "private-value",
      )
      ignore(
        client.execute(
          "INSERT INTO repository_variable(repository_id,name,value) VALUES(1,'REGION','us-east-1')",
        ),
      )
    })
    initialize_db(pool)
    pool.with_client(client => {
      let variable = client.query_one("SELECT * FROM repository_variable")
      assert_eq((variable.get_name("name") : String), "REGION")
      assert_eq((variable.get_name("value") : String), "us-east-1")
      ignore(client.execute("DELETE FROM repository WHERE id=1"))
      assert_true(
        client.query_all("SELECT * FROM repository_variable").is_empty(),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
