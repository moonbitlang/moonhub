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
  ignore(authorize_git_operation(pool, credential, repo, @repository.Write))
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
    DeployKey(_) => {
      guard ["preparing", "prepared", "committed", "aborted"].contains(phase) else {
        raise @domain.BadRequest(message="invalid reference transaction phase")
      }
      // pre-receive validates client refs. This trusted Git transaction may
      // additionally report HEAD as a side effect of updating its branch.
      // A repository credential is never a Pipeline execution principal.
      // Do not attribute this push to its creator or create runnable ref events.
    }
  }
}
