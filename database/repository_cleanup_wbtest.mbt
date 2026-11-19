///|
async test "schemas 38 through 44 upgrade without replaying completed migrations" {
  let baseline = @fs.read_file("db/base.sql").text()
  let storage = @fs.read_file("db/migrations/039_blob_storage.sql").text()
  let releases = @fs.read_file("db/migrations/040_releases.sql").text()
  let cleanup = @fs.read_file("db/migrations/041_repository_cleanup.sql").text()
  let isolation = @fs.read_file("db/migrations/042_worker_isolation.sql").text()
  let environments = @fs.read_file(
    "db/migrations/043_provider_environments.sql",
  ).text()
  let transfers = @fs.read_file("db/migrations/044_repository_transfer.sql").text()
  @async.with_task_group(group => {
    for version in [38, 39, 40, 41, 42, 43, 44] {
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
        if version >= 41 {
          client.batch_execute(cleanup)
        }
        if version >= 42 {
          client.batch_execute(isolation)
        }
        if version >= 43 {
          client.batch_execute(environments)
        }
        if version >= 44 {
          client.batch_execute(transfers)
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
          database_schema_version,
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
        assert_true(
          client.query_all("SELECT * FROM repository_transfer").is_empty(),
        )
        assert_true(
          client
          .query_all("SELECT release_branch FROM repository_ref_event")
          .is_empty(),
        )
        assert_true(
          client
          .query_all("SELECT * FROM pipeline_provider_environment")
          .is_empty(),
        )
      })
    }
  })
}
