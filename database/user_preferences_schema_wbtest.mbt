///|
async test "baseline preserves display preferences and account timestamps" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        "UPDATE \"user\" SET created_at='2024-01-02 03:04:05' WHERE id=1;",
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_true(client.query_all("SELECT * FROM user_preferences").is_empty())
      assert_eq(
        (
          client
          .query_one("SELECT created_at FROM \"user\" WHERE id=1")
          .get_name("created_at") : String),
        "2024-01-02 03:04:05",
      )
      ignore(
        client.execute(
          "INSERT INTO user_preferences(user_id,time_zone) VALUES(1,'Asia/Shanghai')",
        ),
      )
    })
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT time_zone FROM user_preferences WHERE user_id=1")
          .get_name("time_zone") : String),
        "Asia/Shanghai",
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
