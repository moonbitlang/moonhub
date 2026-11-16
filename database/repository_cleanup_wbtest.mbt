///|
async test "schemas 38 through 40 upgrade without replaying completed migrations" {
  let baseline = @fs.read_file("db/base.sql").text()
  let storage = @fs.read_file("db/migrations/039_blob_storage.sql").text()
  let releases = @fs.read_file("db/migrations/040_releases.sql").text()
  @async.with_task_group(group => {
    for version in [38, 39, 40] {
      let pool = new_db_pool({ path: ":memory:", }, group)
      defer pool.close()
      pool.with_client(client => {
        client.batch_execute(baseline)
        if version >= 39 {
          client.batch_execute(storage)
        }
        if version >= 40 {
          client.batch_execute(releases)
        }
        client.batch_execute(
          "PRAGMA user_version=\{version}; INSERT INTO team(name_key,display_name,kind) VALUES('retained','Retained','org');",
        )
      })
      initialize_db(pool)
      initialize_db(pool)
      pool.with_client(client => {
        assert_eq(
          (
            client.query_one("PRAGMA user_version").get_name("user_version") :
            Int64),
          41L,
        )
        assert_eq(
          (
            client
            .query_one("SELECT display_name FROM team")
            .get_name("display_name") : String),
          "Retained",
        )
        assert_true(
          client.query_all("SELECT * FROM repository_file_garbage").is_empty(),
        )
        assert_true(
          client.query_all("SELECT * FROM attachment_file_garbage").is_empty(),
        )
        assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
      })
    }
  })
}
