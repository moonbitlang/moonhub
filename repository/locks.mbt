///|
// Control files outlive repository and mirror data. Never unlink these locks:
// waiters in other processes must keep referring to the same inode.
async fn control_lock_path(
  root : String,
  category : String,
  key : String,
) -> String {
  let root = @domain.trim_trailing_slash(@fs.realpath(root))
  for directory in ["\{root}/.locks", "\{root}/.locks/\{category}"] {
    @fs.mkdir(directory, permission=0o700) catch {
      err => if !@fs.exists(directory) { raise err }
    }
    guard @fs.kind(directory, follow_symlink=false) is Directory &&
      @fs.realpath(directory) == directory else {
      raise @domain.BadRequest(message="invalid repository control directory")
    }
  }
  "\{root}/.locks/\{category}/\{key}.lock"
}

///|
pub async fn repository_write_lock(
  root : String,
  repo : @domain.RepoId,
) -> @fs.File {
  repository_lock(root, repo, Exclusive)
}

///|
pub async fn repository_read_lock(
  root : String,
  repo : @domain.RepoId,
) -> @fs.File {
  repository_lock(root, repo, Shared)
}

///|
async fn repository_lock(
  root : String,
  repo : @domain.RepoId,
  mode : @fs.Lock,
) -> @fs.File {
  let repo = @domain.parse_transport_repo("\{repo.path()}.git")
  let key = @crypto.bytes_to_hex_string(
    @crypto.sha256(@utf8.encode(repo.path())),
  )
  @gitops.file_lock(control_lock_path(root, "repositories", key), mode~)
}

///|
async fn mirror_lock(root : String, id : Int64) -> @fs.File {
  guard id >= 0L else {
    raise @domain.BadRequest(message="invalid mirror identity")
  }
  @gitops.file_lock(control_lock_path(root, "mirrors", id.to_string()))
}
