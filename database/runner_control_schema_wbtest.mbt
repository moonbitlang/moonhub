///|
async test "baseline defaults provider control configuration" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    pool.with_client(client => {
      client.batch_execute(
        "INSERT INTO pipeline_provider(name,token_hash) VALUES('legacy','preserved-hash');",
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let row = client.query_one(
        "SELECT token_hash,mode,config_revision,repository_scope FROM pipeline_provider WHERE name='legacy'",
      )
      assert_eq((row.get_name("token_hash") : String), "preserved-hash")
      assert_eq((row.get_name("mode") : String), "")
      assert_eq((row.get_name("config_revision") : Int64), 0L)
      assert_eq((row.get_name("repository_scope") : String), "selected")
      assert_true(client.query_all("SELECT * FROM pipeline_worker").is_empty())
      assert_true(
        client.query_all("SELECT * FROM repository_mirror").is_empty(),
      )
      assert_true(
        client.query_all("SELECT * FROM mirror_ref_intent").is_empty(),
      )
      assert_true(client.query_all("SELECT * FROM mirror_attempt").is_empty())
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
