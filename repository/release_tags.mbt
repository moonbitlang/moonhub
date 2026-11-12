///|
// Publication seals a tag for every managed writer, including deploy keys.
fn check_release_tag_updates(
  tx : @database.DbTransaction,
  repository_id : Int64,
  phase : String,
  updates : String,
) -> Unit raise {
  guard phase == "prepared" else { return }
  for line in @domain.split_lines(updates) {
    let fields = line.split(" ").map(p => p.to_owned()).collect()
    if fields.length() == 3 &&
      fields[2].has_prefix("refs/tags/") &&
      fields[0] != fields[1] {
      guard tx.query_opt(
          "SELECT id FROM repository_release WHERE repository_id=? AND tag=? AND draft=0 AND deleted=0",
          params=[repository_id, fields[2][10:].to_owned()],
        )
        is None else {
        raise @domain.Forbidden(message="published release tags are immutable")
      }
    }
  }
}
