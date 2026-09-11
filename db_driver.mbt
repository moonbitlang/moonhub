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
let password_cost : Int = 12

///|
fn hash_password(password : String) -> String {
  guard @env.rand(@bcrypt.salt_length) is Some(salt) else {
    abort("secure randomness is unavailable")
  }
  @bcrypt.hash(password=@utf8.encode(password), salt~, cost=password_cost) catch {
    _ => abort("failed to hash password")
  }
}

///|
fn verify_password(password : String, hash : String) -> Bool {
  @bcrypt.verify(password=@utf8.encode(password), hashed=hash) catch {
    _ => false
  }
}

///|
fn random_hex(byte_count : Int) -> String {
  guard @env.rand(byte_count) is Some(bytes) else {
    abort("secure randomness is unavailable")
  }
  @crypto.bytes_to_hex_string(bytes)
}

///|
fn hash_token(token : String) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(token)))
}

///|
struct DbRow {
  row : @moondb.Row
}

///|
trait DbParam {
  fn to_db_value(Self) -> @moondb.Value
}

///|
impl DbParam for String with fn to_db_value(self) {
  @moondb.Text(self)
}

///|
impl DbParam for Int64 with fn to_db_value(self) {
  @moondb.Int64(self)
}

///|
impl DbParam for Bool with fn to_db_value(self) {
  @moondb.Bool(self)
}

///|
fn db_params(params : Array[&DbParam]) -> Array[@moondb.Value] {
  params.map(value => value.to_db_value())
}

///|
trait DbFromValue {
  fn from_db_value(@moondb.Value) -> Self raise @moondb.DbError
}

///|
impl DbFromValue for String with fn from_db_value(value) {
  match value {
    @moondb.Text(value) => value
    _ => raise @moondb.TypeError("expected text value")
  }
}

///|
impl DbFromValue for Int64 with fn from_db_value(value) {
  match value {
    @moondb.Int(value) => value.to_int64()
    @moondb.Int64(value) => value
    _ => raise @moondb.TypeError("expected integer value")
  }
}

///|
impl DbFromValue for Bool with fn from_db_value(value) {
  match value {
    @moondb.Bool(value) => value
    @moondb.Int(value) => value != 0
    @moondb.Int64(value) => value != 0L
    _ => raise @moondb.TypeError("expected boolean value")
  }
}

///|
impl[T : DbFromValue] DbFromValue for T? with fn from_db_value(value) {
  match value {
    @moondb.Null => None
    value => Some(DbFromValue::from_db_value(value))
  }
}

///|
fn[T : DbFromValue] DbRow::get_name(
  self : DbRow,
  name : String,
) -> T raise @moondb.DbError {
  match self.row.by_name(name) {
    Some(value) => DbFromValue::from_db_value(value)
    None => raise @moondb.QueryError("no such column: " + name)
  }
}

///|
fn[A] Database::with_client(
  self : Database,
  f : (DbClient) -> A raise,
) -> A raise {
  f({ driver: self.driver, })
}

///|
fn Database::close(self : Database) -> Unit {
  self.driver.close()
}

///|
fn DbClient::query_all(
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
fn DbClient::query_opt(
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
fn DbClient::execute(
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
fn DbClient::batch_execute(
  self : DbClient,
  sql : String,
) -> Unit raise @moondb.DbError {
  self.driver.exec_script(sql)
}

///|
fn[A] DbClient::with_transaction(
  self : DbClient,
  f : (DbTransaction) -> A raise,
) -> A raise {
  self.driver.begin()
  errdefer self.driver.rollback()
  let result = f({ driver: self.driver, })
  self.driver.commit()
  result
}

///|
fn DbTransaction::query_all(
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
fn DbTransaction::query_one(
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
fn DbTransaction::query_opt(
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
fn DbTransaction::execute(
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
