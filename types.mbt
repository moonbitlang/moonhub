///|
struct Config {
  root : String
  assets_root : String
  host : String
  port : UInt16
  root_user : RootUserConfig
}

///|
struct DbConfig {
  host : String
  port : Int
  user : String
  name : String
  password : String?
  pool_size : Int
}

///|
struct RootUserConfig {
  name_key : String
  initial_password : String
}

///|
struct RepoId {
  owner : String
  name : String
}

///|
fn RepoId::path(self : RepoId) -> String {
  "\{self.owner}/\{self.name}"
}

///|
fn RepoId::git_dir(self : RepoId, root : String) -> String {
  "\{trim_trailing_slash(root)}/\{self.owner}/\{self.name}.git"
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
struct CurrentUser {
  id : Int64
  name_key : String
  display_name : String
  is_site_admin : Bool
}

///|
struct LoginResult {
  token : String
  invitation : InvitationLogin?
}

///|
struct InvitationLogin {
  id : Int64
}

///|
struct InvitationSession {
  id : Int64
  name_key : String
  display_name : String
}

///|
struct TeamSummary {
  id : Int64
  name_key : String
  display_name : String
  kind : String
  role : String?
}

///|
struct TeamMemberSummary {
  name_key : String
  display_name : String
  email : String?
  role : String
}

///|
struct InvitationSummary {
  id : Int64
  email : String
  name_key : String
  display_name : String
  role : String?
  status : String
  email_status : String?
  email_sent_at : String?
  email_last_error : String?
}

///|
