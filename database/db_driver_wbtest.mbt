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

///|
test "immediate transactions roll back failures and allow the next transaction" {
  let db : Database = { driver: @sqlite.SqliteDriver::open(":memory:"), }
  defer db.close()
  db.with_client(client => {
    client.batch_execute("CREATE TABLE item (id INTEGER PRIMARY KEY)")
    let rejected = try {
      client.with_transaction(
        tx => {
          ignore(tx.execute("INSERT INTO item VALUES (1)"))
          ignore(tx.execute("INSERT INTO item VALUES (1)"))
        },
        immediate=true,
      )
      false
    } catch {
      @moondb.QueryError(_) => true
      err => raise err
    }
    assert_true(rejected)
    assert_true(client.query_all("SELECT * FROM item").is_empty())
    client.with_transaction(
      tx => {
        ignore(tx.execute("INSERT INTO item VALUES (2)"))
        assert_eq(tx.query_all("SELECT * FROM item").length(), 1)
      },
      immediate=true,
    )
    assert_eq(
      (client.query_one("SELECT id FROM item").get_name("id") : Int64),
      2L,
    )
  })
}
