///|
pub async fn check_received_refs(
  pool : @database.Database,
  credential : SshCredential,
  repo : @domain.RepoId,
) -> Unit {
  let updates = read_ref_updates()
  @collaboration.check_received_ref_rules(
    pool,
    authorize_git_operation(pool, credential, repo, @repository.Write),
    updates,
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
  credential : SshCredential,
  repo : @domain.RepoId,
  source_key : String,
  phase : String,
) -> Unit {
  let updates = read_ref_updates()
  let scope = authorize_git_operation(pool, credential, repo, @repository.Write)
  match credential {
    UserKey(id) =>
      @repository.record_received_transaction(
        pool,
        ssh_key_user(pool, id),
        repo,
        source_key,
        phase,
        updates,
      )
    DeployKey(id) =>
      @repository.record_deploy_key_webhook_transaction(
        pool, scope, id, source_key, phase, updates,
      )
  }
}
