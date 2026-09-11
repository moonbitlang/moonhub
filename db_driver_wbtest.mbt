///|
impl DbFromValue for Int with fn from_db_value(value) {
  match value {
    @moondb.Int(value) => value
    @moondb.Int64(value) => value.to_int()
    _ => raise @moondb.TypeError("expected integer value")
  }
}

///|
fn DbClient::query_one(
  self : DbClient,
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
test "database query_one requires exactly one row" {
  let db : Database = { driver: @sqlite.SqliteDriver::open(":memory:"), }
  defer db.close()
  db.with_client(client => {
    let row = client.query_one("SELECT 42 AS answer")
    assert_eq((row.get_name("answer") : Int), 42)
    for sql in ["SELECT 1 WHERE 0", "SELECT 1 UNION ALL SELECT 2"] {
      let rejected = try {
        ignore(client.query_one(sql))
        false
      } catch {
        @moondb.QueryError(_) => true
        err => raise err
      }
      assert_true(rejected)
    }
  })
}
