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
pub let database_schema_version : Int64 = 48L

///|
let database_initialization_state : String =
  #|SELECT user_version,
  #|  EXISTS (SELECT 1 FROM sqlite_schema WHERE name NOT GLOB 'sqlite_*') AS has_objects
  #|FROM pragma_user_version

///|
fn database_needs_initialization(state : DbRow) -> Bool raise {
  let version : Int64 = state.get_name("user_version")
  if version == database_schema_version {
    return false
  }
  guard version <= database_schema_version else {
    raise @domain.BadRequest(
      message="database schema is newer than this moonhub version",
    )
  }
  guard version == 0L || version >= 38L else {
    raise @domain.BadRequest(
      message="database schema \{version} is older than the minimum supported version 38; upgrade it to schema 38 with a historical MoonHub release first",
    )
  }
  guard version != 0L || !(state.get_name("has_objects") : Bool) else {
    raise @domain.BadRequest(
      message="database has schema version 0 but contains user-defined objects; restore a complete database or upgrade it to schema 38 with a historical MoonHub release first",
    )
  }
  true
}

///|
fn initialize_database_schema(
  client : DbClient,
  baseline : String?,
  migrations : Array[(Int64, String)],
) -> Unit raise {
  client.with_transaction(
    tx => {
      // Reserve the writer before rechecking: another initializer may have
      // committed while the scripts were being read.
      let state = tx.query_one(database_initialization_state)
      if database_needs_initialization(state) {
        let version : Int64 = state.get_name("user_version")
        if version == 0L {
          guard baseline is Some(sql) else {
            raise @domain.BadRequest(
              message="database state changed during initialization; retry initialization",
            )
          }
          tx.driver.exec_script(sql)
        }
        // Apply only missing versions; migration 040 contains ALTER TABLE.
        // The baseline, migrations and version commit atomically.
        for target in [39L, 40L, 41L, 42L, 43L, 44L, 45L, 46L, 47L, 48L] {
          if version < target {
            guard migrations.iter().find_first(item => item.0 == target)
              is Some((_, sql)) else {
              raise @domain.BadRequest(
                message="database state changed during initialization; retry initialization",
              )
            }
            tx.driver.exec_script(sql)
          }
        }
        ignore(tx.execute("PRAGMA user_version = \{database_schema_version}"))
      }
    },
    immediate=true,
  )
}

///|
pub async fn initialize_db(pool : Database) -> Unit {
  let state = pool.with_client(client => {
    ignore(client.execute("PRAGMA foreign_keys = ON"))
    ignore(client.execute("PRAGMA journal_mode = WAL"))
    ignore(client.execute("PRAGMA busy_timeout = 5000"))
    client.query_one(database_initialization_state)
  })
  if database_needs_initialization(state) {
    let version : Int64 = state.get_name("user_version")
    let baseline = if version == 0L {
      Some(@fs.read_file("db/base.sql").text())
    } else {
      None
    }
    let migrations : Array[(Int64, String)] = []
    for
      (target, path) in [
        (39L, "db/migrations/039_blob_storage.sql"),
        (40L, "db/migrations/040_releases.sql"),
        (41L, "db/migrations/041_repository_cleanup.sql"),
        (42L, "db/migrations/042_worker_isolation.sql"),
        (43L, "db/migrations/043_provider_environments.sql"),
        (44L, "db/migrations/044_repository_transfer.sql"),
        (45L, "db/migrations/045_release_workflows.sql"),
        (46L, "db/migrations/046_windows_vm_routing.sql"),
        (47L, "db/migrations/047_disposable_asg_only.sql"),
        (48L, "db/migrations/048_runner_groups.sql"),
      ] {
      if version < target {
        migrations.push((target, @fs.read_file(path).text()))
      }
    }
    pool.with_client(client => {
      initialize_database_schema(client, baseline, migrations)
    })
  }
}
