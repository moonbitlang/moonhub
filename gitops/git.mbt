///|
pub fn git_args(git_dir : String, args : Array[String]) -> Array[String] {
  let full_args = ["--no-pager", "--git-dir=\{git_dir}"]
  for arg in args {
    full_args.push(arg)
  }
  full_args
}

///|
pub(all) suberror GitError {
  GitCommandFailed(code~ : Int, output~ : String)
}

///|
pub impl Show for GitError with fn output(self, logger) {
  let GitCommandFailed(code~, output~) = self
  logger.write_string("Git exited with status \{code}: \{output}")
}

///|
pub async fn run_git(git_dir : String, args : Array[String]) -> String {
  let full_args = git_args(git_dir, args)
  let (code, output) = @process.collect_output_merged("git", full_args)
  let output = output.text() catch {
    _ => output.binary().to_unchecked_string()
  }
  guard code == 0 else { raise GitCommandFailed(code~, output~) }
  output
}

///|
pub async fn default_ref(git_dir : String) -> String {
  let out = run_git(git_dir, ["symbolic-ref", "--quiet", "--short", "HEAD"]) catch {
    GitCommandFailed(code=1, ..) => return "HEAD"
    err => raise err
  }
  let lines = @domain.split_lines(out)
  match lines.get(0) {
    Some(line) => line
    None => "HEAD"
  }
}

///|
pub async fn is_unborn_default_ref(git_dir : String, rev : String) -> Bool {
  rev == default_ref(git_dir) &&
  run_git(git_dir, ["for-each-ref", "--count=1", "--format=%(refname)"]).is_empty()
}

///|
pub async fn resolve_ref(git_dir : String, rev : String?) -> String {
  match rev {
    Some(v) if @domain.valid_repo_path(v) => v
    _ => default_ref(git_dir)
  }
}

///|
pub async fn resolve_ref_path(
  git_dir : String,
  rev : String,
  path : String,
) -> (String, String) {
  let combined = "\{rev}/\{path}"
  let refs = run_git(git_dir, [
    "for-each-ref", "--format=%(refname:strip=2)", "refs/heads/", "refs/tags/",
  ])
  let mut matched_ref = rev
  let mut matched_path = path
  // URL segments do not mark where a slash-containing ref ends. Prefer the
  // longest named ref; otherwise preserve single-segment revisions such as HEAD.
  for candidate in @domain.split_lines(refs) {
    if candidate.length() > matched_ref.length() {
      if combined == candidate {
        matched_ref = candidate
        matched_path = ""
      } else if combined.has_prefix("\{candidate}/") {
        matched_ref = candidate
        matched_path = combined[candidate.length() + 1:].to_owned()
      }
    }
  }
  (matched_ref, matched_path)
}

///|
pub async fn is_directory(path : String) -> Bool {
  try @fs.kind(path) catch {
    _ => false
  } noraise {
    kind => kind is Directory
  }
}

///|
pub async fn list_repositories(root : String) -> Array[@domain.RepoId] {
  let repos : Array[@domain.RepoId] = []
  let owners = @fs.readdir(root, sort=true) catch { _ => [] }
  owners.sort()
  for owner in owners {
    let owner_dir = "\{@domain.trim_trailing_slash(root)}/\{owner}"
    if @domain.valid_repo_owner(owner) && is_directory(owner_dir) {
      let names = @fs.readdir(owner_dir, sort=true) catch { _ => [] }
      names.sort()
      for dir in names {
        match @domain.strip_git_suffix(dir) {
          Some(name) =>
            if @domain.valid_segment(name) &&
              @fs.exists("\{owner_dir}/\{dir}/HEAD") {
              repos.push({ owner, name, })
            }
          _ => ()
        }
      }
    }
  }
  repos
}

///|
fn parse_tree_entry(line : String) -> TreeEntry? {
  match line.split_once("\t") {
    Some((meta, name_view)) => {
      let meta_parts = meta
        .to_owned()
        .split(" ")
        .filter(v => !v.is_empty())
        .map(v => v.to_owned())
        .collect()
      if meta_parts.length() >= 3 {
        let size = if meta_parts.length() >= 4 && meta_parts[3] != "-" {
          Some(meta_parts[3])
        } else {
          None
        }
        Some({ kind: meta_parts[1], size, name: name_view.to_owned(), })
      } else {
        None
      }
    }
    None => None
  }
}

///|
pub async fn list_tree(
  git_dir : String,
  rev : String,
  path : String,
) -> Array[TreeEntry] {
  let spec = if path.is_empty() { rev } else { "\{rev}:\{path}" }
  let out = run_git(git_dir, ["ls-tree", "-l", spec])
  let entries : Array[TreeEntry] = []
  for line in @domain.split_lines(out) {
    match parse_tree_entry(line) {
      Some(entry) => entries.push(entry)
      None => ()
    }
  }
  entries.sort_by((left, right) => {
    if left.kind == "tree" && right.kind != "tree" {
      -1
    } else if left.kind != "tree" && right.kind == "tree" {
      1
    } else {
      left.name.lexical_compare(right.name)
    }
  })
  entries
}

///|
pub async fn read_blob(git_dir : String, rev : String, path : String) -> String {
  run_git(git_dir, ["show", "\{rev}:\{path}"])
}

///|
pub fn parse_commit_line(line : String) -> CommitInfo? {
  let parts = line.split("\u{1f}").map(v => v.to_owned()).collect()
  if parts.length() >= 4 {
    Some({
      hash: parts[0],
      subject: parts[1],
      author: parts[2],
      date: parts[3],
    })
  } else {
    None
  }
}

///|
pub async fn list_commits(git_dir : String, rev : String) -> Array[CommitInfo] {
  let out = run_git(git_dir, [
    "log", "--date=short", "--pretty=format:%H%x1f%s%x1f%an%x1f%ad", "-n", "50",
    rev,
  ])
  let commits : Array[CommitInfo] = []
  for line in @domain.split_lines(out) {
    match parse_commit_line(line) {
      Some(commit) => commits.push(commit)
      None => ()
    }
  }
  commits
}
