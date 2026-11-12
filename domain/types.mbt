///|
pub(all) struct RepoId {
  owner : String
  name : String
}

///|
pub fn RepoId::path(self : RepoId) -> String {
  "\{self.owner}/\{self.name}"
}

///|
pub fn RepoId::git_dir(self : RepoId, root : String) -> String {
  "\{trim_trailing_slash(root)}/\{self.owner}/\{self.name}.git"
}

///|
pub(all) struct CurrentUser {
  id : Int64
  name_key : String
  display_name : String
  is_site_admin : Bool
  time_zone : String?
}
