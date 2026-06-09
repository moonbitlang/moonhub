///|
fn trim_trailing_slash(path : String) -> String {
  let mut out = path
  while out.length() > 1 && out.has_suffix("/") {
    out = out[:out.length() - 1].to_owned()
  }
  out
}

///|
fn strip_git_suffix(name : String) -> String? {
  match name.strip_suffix(".git") {
    Some(v) => Some(v.to_owned())
    None => None
  }
}

///|
fn valid_segment(s : String) -> Bool {
  !s.is_empty() && !s.contains("/") && s != "." && s != ".."
}

///|
let public_assets_owner : String = "assets"

///|
fn valid_repo_owner(s : String) -> Bool {
  valid_segment(s) && s != public_assets_owner
}

///|
fn url_escape_path(s : String) -> String {
  s
  .replace_all(old=" ", new="%20")
  .replace_all(old="#", new="%23")
  .replace_all(old="?", new="%3F")
}

///|
fn split_lines(s : String) -> Array[String] {
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
