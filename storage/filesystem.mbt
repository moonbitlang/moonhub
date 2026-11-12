///|
async fn fs_directory(
  root : String,
  scope_key : String,
  create : Bool,
) -> String {
  namespace_key(scope_key)
  if create {
    @fs.mkdir(root, recursive=true, permission=0o700, allow_exist=true)
  }
  guard @fs.kind(root, follow_symlink=false) is Directory else {
    raise IntegrityFailure
  }
  let directory = root + "/" + scope_key
  if create {
    @fs.mkdir(directory, permission=0o700, allow_exist=true)
  }
  guard @fs.kind(directory, follow_symlink=false) is Directory else {
    raise IntegrityFailure
  }
  directory
}

///|
async fn fs_path(root : String, key : String, create : Bool) -> String {
  object_key(key)
  let (scope_key, file) = key.split_once("/").unwrap()
  fs_directory(root, scope_key.to_owned(), create) + "/" + file.to_owned()
}

///|
async fn fs_remove_tree(path : String) -> Unit {
  try {
    match @fs.kind(path, follow_symlink=false) {
      Regular => @fs.remove(path)
      Directory => {
        for name in @fs.readdir(path, include_hidden=true) {
          fs_remove_tree(path + "/" + name)
        }
        @fs.rmdir(path)
      }
      _ => raise IntegrityFailure
    }
  } catch {
    // Repository deletion and garbage collection may reclaim the same files.
    @os_error.OSError(_) as err if err.is_ENOENT() => ()
    err => raise err
  }
}
