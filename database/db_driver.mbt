///|
struct Database {
  driver : @sqlite.SqliteDriver
}

///|
struct DbClient {
  driver : @sqlite.SqliteDriver
}

///|
struct DbTransaction {
  driver : @sqlite.SqliteDriver
}

///|
struct DbRow {
  row : @moondb.Row
}

///|
pub trait DbParam {
  fn to_db_value(Self) -> @moondb.Value
}

///|
pub impl DbParam for String with fn to_db_value(self) {
  @moondb.Text(self)
}

///|
pub impl DbParam for Int64 with fn to_db_value(self) {
  @moondb.Int64(self)
}

///|
pub impl DbParam for Bool with fn to_db_value(self) {
  @moondb.Bool(self)
}

///|
fn db_params(params : Array[&DbParam]) -> Array[@moondb.Value] {
  params.map(value => value.to_db_value())
}

///|
pub trait DbFromValue {
  fn from_db_value(@moondb.Value) -> Self raise @moondb.DbError
}

///|
pub impl DbFromValue for String with fn from_db_value(value) {
  match value {
    @moondb.Text(value) => value
    _ => raise @moondb.TypeError("expected text value")
  }
}

///|
pub impl DbFromValue for Int64 with fn from_db_value(value) {
  match value {
    @moondb.Int(value) => value.to_int64()
    @moondb.Int64(value) => value
    _ => raise @moondb.TypeError("expected integer value")
  }
}

///|
pub impl DbFromValue for Bool with fn from_db_value(value) {
  match value {
    @moondb.Bool(value) => value
    @moondb.Int(value) => value != 0
    @moondb.Int64(value) => value != 0L
    _ => raise @moondb.TypeError("expected boolean value")
  }
}

///|
pub impl[T : DbFromValue] DbFromValue for T? with fn from_db_value(value) {
  match value {
    @moondb.Null => None
    value => Some(DbFromValue::from_db_value(value))
  }
}

///|
pub fn[T : DbFromValue] DbRow::get_name(
  self : DbRow,
  name : String,
) -> T raise @moondb.DbError {
  match self.row.by_name(name) {
    Some(value) => DbFromValue::from_db_value(value)
    None => raise @moondb.QueryError("no such column: " + name)
  }
}

///|
pub fn[A] Database::with_client(
  self : Database,
  f : (DbClient) -> A raise,
) -> A raise {
  f({ driver: self.driver, })
}

///|
pub fn Database::close(self : Database) -> Unit {
  self.driver.close()
}

///|
pub fn DbClient::query_all(
  self : DbClient,
  sql : String,
  params? : Array[&DbParam] = [],
) -> Array[DbRow] raise @moondb.DbError {
  self.driver.query(sql, db_params(params)).map(row => { row, }) catch {
    @moondb.QueryError(message) =>
      raise @moondb.QueryError("\{message}; sql=\{sql}")
    err => raise err
  }
}

///|
pub fn DbClient::query_opt(
  self : DbClient,
  sql : String,
  params? : Array[&DbParam] = [],
) -> DbRow? raise @moondb.DbError {
  let rows = self.query_all(sql, params~)
  guard rows.length() <= 1 else {
    raise @moondb.QueryError(
      "expected zero or one row, got \{rows.length().to_string()}",
    )
  }
  if rows.is_empty() {
    None
  } else {
    Some(rows[0])
  }
}

///|
pub fn DbClient::execute(
  self : DbClient,
  sql : String,
  params? : Array[&DbParam] = [],
) -> Int raise @moondb.DbError {
  self.driver.execute(sql, db_params(params)).rows_affected.to_int() catch {
    @moondb.QueryError(message) =>
      raise @moondb.QueryError("\{message}; sql=\{sql}")
    err => raise err
  }
}

///|
pub fn DbClient::batch_execute(
  self : DbClient,
  sql : String,
) -> Unit raise @moondb.DbError {
  self.driver.exec_script(sql)
}

///|
pub fn[A] DbClient::with_transaction(
  self : DbClient,
  f : (DbTransaction) -> A raise,
  immediate? : Bool = false,
) -> A raise {
  if immediate {
    self.driver.exec_script("BEGIN IMMEDIATE")
  } else {
    self.driver.begin()
  }
  errdefer self.driver.rollback()
  let result = f({ driver: self.driver, })
  self.driver.commit()
  result
}

///|
pub fn DbTransaction::query_all(
  self : DbTransaction,
  sql : String,
  params? : Array[&DbParam] = [],
) -> Array[DbRow] raise @moondb.DbError {
  self.driver.query(sql, db_params(params)).map(row => { row, }) catch {
    @moondb.QueryError(message) =>
      raise @moondb.QueryError("\{message}; sql=\{sql}")
    err => raise err
  }
}

///|
pub fn DbTransaction::query_one(
  self : DbTransaction,
  sql : String,
  params? : Array[&DbParam] = [],
) -> DbRow raise @moondb.DbError {
  let rows = self.query_all(sql, params~)
  guard rows.length() == 1 else {
    raise @moondb.QueryError(
      "expected exactly one row, got \{rows.length().to_string()}",
    )
  }
  rows[0]
}

///|
pub fn DbTransaction::query_opt(
  self : DbTransaction,
  sql : String,
  params? : Array[&DbParam] = [],
) -> DbRow? raise @moondb.DbError {
  let rows = self.query_all(sql, params~)
  guard rows.length() <= 1 else {
    raise @moondb.QueryError(
      "expected zero or one row, got \{rows.length().to_string()}",
    )
  }
  if rows.is_empty() {
    None
  } else {
    Some(rows[0])
  }
}

///|
pub fn DbTransaction::execute(
  self : DbTransaction,
  sql : String,
  params? : Array[&DbParam] = [],
) -> Int raise @moondb.DbError {
  self.driver.execute(sql, db_params(params)).rows_affected.to_int() catch {
    @moondb.QueryError(message) =>
      raise @moondb.QueryError("\{message}; sql=\{sql}")
    err => raise err
  }
}
