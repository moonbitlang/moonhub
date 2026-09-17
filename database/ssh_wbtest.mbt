///|
async test "SSH migration upgrades existing databases and is repeatable" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    let baseline = @fs.read_file("db/base.sql").text()
    pool.with_client(client => {
      client.batch_execute(baseline)
      let _ = client.execute(
        "INSERT INTO team (name_key, display_name, kind) VALUES ('existing', 'Existing', 'org')",
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_true(
        client.query_opt("SELECT id FROM team WHERE name_key = 'existing'")
        is Some(_),
      )
      assert_true(
        client.query_opt(
          "SELECT name FROM sqlite_master WHERE name = 'ssh_key'",
        )
        is Some(_),
      )
      let row = client.query_opt("PRAGMA user_version").unwrap()
      let version : Int64 = row.get_name("user_version")
      assert_eq(version, database_schema_version)
    })
  })
}
