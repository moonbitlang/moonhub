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
fn split_path(path : StringView) -> Array[String] {
  let parts : Array[String] = []
  for part in path.split("/") {
    if !part.is_empty() {
      parts.push(part.to_owned())
    }
  }
  parts
}

///|
fn valid_segment(s : String) -> Bool {
  !s.is_empty() && !s.contains("/") && s != "." && s != ".."
}

///|
fn parse_repo_id(parts : Array[String]) -> RepoId? {
  if parts.length() < 2 {
    None
  } else {
    let owner = parts[0]
    let name = parts[1]
    if valid_segment(owner) && valid_segment(name) {
      Some({ owner, name })
    } else {
      None
    }
  }
}

///|
fn rest_path(parts : Array[String], from~ : Int) -> String {
  let tail : Array[String] = []
  for i in from..<parts.length() {
    if valid_segment(parts[i]) {
      tail.push(parts[i])
    }
  }
  tail.join("/")
}

///|
fn html_escape(s : String) -> String {
  let b = StringBuilder()
  for ch in s {
    match ch {
      '&' => b.write_string("&amp;")
      '<' => b.write_string("&lt;")
      '>' => b.write_string("&gt;")
      '"' => b.write_string("&quot;")
      '\'' => b.write_string("&#39;")
      _ => b.write_char(ch)
    }
  }
  b.to_string()
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
