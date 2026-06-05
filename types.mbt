///|
struct Config {
  root : String
  host : String
  port : UInt16
}

///|
struct RepoId {
  owner : String
  name : String
}

///|
fn RepoId::path(self : RepoId) -> String {
  self.owner + "/" + self.name
}

///|
fn RepoId::git_dir(self : RepoId, root : String) -> String {
  trim_trailing_slash(root) + "/" + self.owner + "/" + self.name + ".git"
}

///|
struct TreeEntry {
  kind : String
  size : String?
  name : String
}

///|
struct CommitInfo {
  hash : String
  subject : String
  author : String
  date : String
}

///|
