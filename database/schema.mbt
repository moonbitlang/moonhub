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
pub let database_schema_version : Int64 = 40L

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
  storage_migration : String,
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
        // The schema 38 baseline and all later migrations commit together.
        tx.driver.exec_script(storage_migration)
        ignore(tx.execute("PRAGMA user_version = 40"))
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
    let storage_migration = @fs.read_file("db/migrations/039_blob_storage.sql").text()
    let release_migration = @fs.read_file("db/migrations/040_releases.sql").text()
    pool.with_client(client => {
      initialize_database_schema(
        client,
        baseline,
        storage_migration + "\n" + release_migration,
      )
    })
  }
}
