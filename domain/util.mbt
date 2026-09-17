///|
pub fn trim_trailing_slash(path : String) -> String {
  let mut out = path
  while out.length() > 1 && out.has_suffix("/") {
    out = out[:out.length() - 1].to_owned()
  }
  out
}

///|
pub fn strip_git_suffix(name : String) -> String? {
  match name.strip_suffix(".git") {
    Some(v) => Some(v.to_owned())
    None => None
  }
}

///|
pub fn valid_segment(s : String) -> Bool {
  !s.is_empty() && !s.contains("/") && s != "." && s != ".."
}

///|
pub const PUBLIC_ASSETS_OWNER : String = "assets"

///|
/// Path segment that separates framework routes from namespaces and
/// repositories: global pages live under `/-/`, namespace pages under
/// `/<namespace>/-/`. It is never a namespace or repository name.
const RESERVED_PATH_SEGMENT : String = "-"

///|
pub fn valid_repo_owner(s : String) -> Bool {
  valid_segment(s) && s != PUBLIC_ASSETS_OWNER && s != RESERVED_PATH_SEGMENT
}

///|
pub fn valid_repo_name(s : String) -> Bool {
  valid_segment(s) && s != RESERVED_PATH_SEGMENT
}

///|
pub fn valid_name_key(s : String) -> Bool {
  guard !s.is_empty() && s.length() <= 63 else { return false }
  for i, ch in s {
    if i == 0 {
      guard ch.is_ascii_lowercase() || ch.is_ascii_digit() else { return false }
    } else {
      guard ch.is_ascii_lowercase() ||
        ch.is_ascii_digit() ||
        ch == '-' ||
        ch == '_' else {
        return false
      }
    }
  }
  s != PUBLIC_ASSETS_OWNER
}

///|
pub fn valid_email(s : String) -> Bool {
  s.length() <= 254 &&
  s == s.to_lower() &&
  s.iter().all(ch => ch.to_int() > 32 && ch.to_int() != 127) &&
  @core.Mailbox::address_only(s) is Ok(_)
}

///|
pub fn normalize_email(s : String) -> String {
  s.trim().to_owned().to_lower()
}

///|
pub fn valid_team_invite_role(role : String) -> Bool {
  role == "admin" || role == "member"
}

///|
pub fn split_lines(s : String) -> Array[String] {
  let lines : Array[String] = []
  for line in s.split("\n") {
    let line = match line.strip_suffix("\r") {
      Some(v) => v.to_owned()
      None => line.to_owned()
    }
    if !line.is_empty() {
      lines.push(line)
    }
  }
  lines
}
