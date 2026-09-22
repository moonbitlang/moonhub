///|
pub async fn check_received_refs(
  pool : @database.Database,
  key_id : Int64,
  repo : @domain.RepoId,
) -> Unit {
  @collaboration.authorize_received_refs(
    pool,
    ssh_key_user(pool, key_id),
    repo,
    read_ref_updates(),
  )
}

///|
async fn read_ref_updates() -> String {
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
  updates
}

///|
pub async fn record_ref_transaction(
  pool : @database.Database,
  key_id : Int64,
  repo : @domain.RepoId,
  source_key : String,
  phase : String,
) -> Unit {
  @repository.record_received_transaction(
    pool,
    ssh_key_user(pool, key_id),
    repo,
    source_key,
    phase,
    read_ref_updates(),
  )
}
