///|
pub async fn cleanup_repository_files(
  root : String,
  ids : Array[String],
) -> Unit {
  for id in ids {
    guard valid_id(id) else {
      raise @domain.BadRequest(message="invalid attachment cleanup identity")
    }
    @repository.remove_cleanup_path(root, ".attachments/" + id)
    @repository.remove_cleanup_path(root, ".attachments/" + id + ".tmp")
  }
}
