///|
pub fn[T] new_db_pool(
  config : DbConfig,
  group : @async.TaskGroup[T],
) -> Database raise @moondb.DbError {
  ignore(group)
  let driver = @sqlite.SqliteDriver::open(config.path)
  errdefer driver.close()
  let _ = driver.execute("PRAGMA foreign_keys = ON", [])
  let _ = driver.execute("PRAGMA busy_timeout = 5000", [])
  { driver, }
}

///|
pub let database_schema_version : Int64 = 18L

///|
pub async fn initialize_db(pool : Database) -> Unit {
  pool.with_client(client => {
    let _ = client.execute("PRAGMA foreign_keys = ON", params=[])
    let _ = client.execute("PRAGMA journal_mode = WAL", params=[])
    let _ = client.execute("PRAGMA busy_timeout = 5000", params=[])
  })
  let table_row = pool.with_client(client => {
    client.query_opt(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'user'",
    )
  })
  if table_row is None {
    let sql = @fs.read_file("db/base.sql").text()
    pool.with_client(client => client.batch_execute(sql))
  }
  let ssh_migration = @fs.read_file("db/migrations/001_ssh_keys.sql").text()
  let repository_migration = @fs.read_file(
    "db/migrations/002_repository_jobs.sql",
  ).text()
  let address_migration = @fs.read_file("db/migrations/003_ssh_addresses.sql").text()
  let merge_migration = @fs.read_file("db/migrations/004_merge_requests.sql").text()
  let mail_migration = @fs.read_file("db/migrations/005_mail_settings.sql").text()
  let personal_namespace_migration = @fs.read_file(
    "db/migrations/006_personal_namespaces.sql",
  ).text()
  let pipeline_migration = @fs.read_file("db/migrations/007_pipelines.sql").text()
  let protocol_migration = @fs.read_file(
    "db/migrations/008_pipeline_protocol.sql",
  ).text()
  let runner_migration = @fs.read_file("db/migrations/009_runner_steps.sql").text()
  let password_reset_migration = @fs.read_file(
    "db/migrations/010_password_resets.sql",
  ).text()
  let provider_scope_migration = @fs.read_file(
    "db/migrations/011_provider_scope.sql",
  ).text()
  let push_migration = @fs.read_file("db/migrations/012_pipeline_push.sql").text()
  let deploy_key_migration = @fs.read_file(
    "db/migrations/013_repository_deploy_keys.sql",
  ).text()
  let merge_checks_migration = @fs.read_file(
    "db/migrations/014_merge_checks.sql",
  ).text()
  let notifications_migration = @fs.read_file(
    "db/migrations/015_notifications.sql",
  ).text()
  let access_tokens_migration = @fs.read_file(
    "db/migrations/016_access_tokens.sql",
  ).text()
  let pull_request_migration = @fs.read_file(
    "db/migrations/017_pull_request_workflows.sql",
  ).text()
  let run_context_migration = @fs.read_file("db/migrations/018_run_context.sql").text()
  pool.with_client(client => {
    client.with_transaction(tx => {
      let row = tx.query_one("PRAGMA user_version")
      let version : Int64 = row.get_name("user_version")
      guard version <= database_schema_version else {
        raise @domain.BadRequest(
          message="database schema is newer than this moonhub version",
        )
      }
      if version == 0L {
        tx.driver.exec_script(ssh_migration)
      }
      if version < 2L {
        tx.driver.exec_script(repository_migration)
      }
      if version < 3L {
        tx.driver.exec_script(address_migration)
      }
      if version < 4L {
        tx.driver.exec_script(merge_migration)
      }
      if version < 5L {
        tx.driver.exec_script(mail_migration)
      }
      if version < 6L {
        tx.driver.exec_script(personal_namespace_migration)
      }
      if version < 7L {
        tx.driver.exec_script(pipeline_migration)
      }
      if version < 8L {
        tx.driver.exec_script(protocol_migration)
      }
      if version < 9L {
        tx.driver.exec_script(runner_migration)
      }
      if version < 10L {
        tx.driver.exec_script(password_reset_migration)
      }
      if version < 11L {
        tx.driver.exec_script(provider_scope_migration)
      }
      if version < 12L {
        tx.driver.exec_script(push_migration)
      }
      if version < 13L {
        tx.driver.exec_script(deploy_key_migration)
      }
      if version < 14L {
        tx.driver.exec_script(merge_checks_migration)
      }
      if version < 15L {
        tx.driver.exec_script(notifications_migration)
      }
      if version < 16L {
        tx.driver.exec_script(access_tokens_migration)
      }
      if version < 17L {
        tx.driver.exec_script(pull_request_migration)
      }
      if version < 18L {
        tx.driver.exec_script(run_context_migration)
      }
      let _ = tx.execute("PRAGMA user_version = 18")
    })
  })
}
