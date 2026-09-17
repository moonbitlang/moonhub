///|
test "database query_one requires exactly one row" {
  let db : Database = { driver: @sqlite.SqliteDriver::open(":memory:"), }
  defer db.close()
  db.with_client(client => {
    let row = client.query_one("SELECT 42 AS answer")
    assert_eq((row.get_name("answer") : Int64), 42L)
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
