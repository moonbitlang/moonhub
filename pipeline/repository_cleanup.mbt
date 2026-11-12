///|
pub async fn Coordinator::cleanup_repository_files(
  self : Coordinator,
  root : String,
  keys : Array[String],
) -> Unit {
  for key in keys {
    guard key.length() == 64 &&
      key.iter().all(ch => ch.is_ascii_digit() || ('a' <= ch && ch <= 'f')) else {
      raise @domain.BadRequest(message="invalid artifact cleanup identity")
    }
    let locations : Array[String] = self.pool.with_client(client => {
      client
      .query_all(
        "SELECT location FROM pipeline_blob_garbage WHERE key=? AND kind='namespace'",
        params=[key],
      )
      .map(row => row.get_name("location"))
    })
    if locations.is_empty() {
      // A previous garbage sweep may already have removed the persisted intent.
      self.blob_store(root, "legacy-fs").remove_namespace(key)
    } else {
      for location in locations {
        self.blob_store(root, location).remove_namespace(key)
      }
    }
    // Keep the cascade intent for its delayed sweep: an upload authorized before
    // deletion may finish after this initial cleanup, including on S3.
  }
}
