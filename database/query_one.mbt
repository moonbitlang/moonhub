///|
pub fn DbClient::query_one(
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
