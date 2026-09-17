///|
pub async fn check_received_refs(
  pool : @database.Database,
  key_id : Int64,
  repo : @domain.RepoId,
) -> Unit {
  let bytes = FixedArray::make(1048577, b'\x00')
  let mut length = 0
  while length < bytes.length() {
    let count = @stdio.stdin.read(
      bytes,
      offset=length,
      max_len=bytes.length() - length,
    )
    if count == 0 {
      break
    }
    length += count
  }
  guard length <= 1048576 else {
    raise @domain.BadRequest(message="too many ref updates")
  }
  let updates = @utf8.decode(Bytes::from_array(bytes)[:length]) catch {
    _ => raise @domain.BadRequest(message="invalid ref update encoding")
  }
  @collaboration.authorize_received_refs(
    pool,
    ssh_key_user(pool, key_id),
    repo,
    updates,
  )
}
