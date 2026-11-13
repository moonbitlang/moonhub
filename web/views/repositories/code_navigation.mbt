///|
priv struct CodeNavigation {
  refs : Array[(String, String)]
  paths : Array[String]
  truncated : Bool
}

///|
// Only called after the browser route has authorized the repository. Bound Git
// output independently of the 5,000-path presentation limit.
async fn code_navigation(git_dir : String, rev : String) -> CodeNavigation {
  let refs : Array[(String, String)] = []
  let (code, output) = @gitops.merge_git_command(git_dir, [
    "for-each-ref", "--format=%(refname)%00%(objectname)", "refs/heads/", "refs/tags/",
  ]) catch {
    _ => (1, "")
  }
  if code == 0 {
    let lines = output
      .split("\n")
      .filter(line => !line.is_empty())
      .map(line => line.to_owned())
      .collect()
    let tag_names : Array[String] = []
    for line in lines {
      let parts = line.split("\u{0}").collect()
      if parts.length() == 2 && parts[0].has_prefix("refs/tags/") {
        tag_names.push(parts[0][10:].to_owned())
      }
    }
    for line in lines {
      let parts = line.split("\u{0}").collect()
      if parts.length() == 2 {
        let full = parts[0].to_owned()
        let sha = parts[1].to_owned()
        if full.has_prefix("refs/heads/") {
          let name = full[11:].to_owned()
          refs.push(
            (
              if tag_names.contains(name) {
                sha
              } else {
                name
              },
              "Branch: " + name,
            ),
          )
        } else if full.has_prefix("refs/tags/") {
          refs.push((sha, "Tag: " + full[10:].to_owned()))
        }
      }
    }
  }
  let (paths, truncated) = try {
    let (code, output) = @gitops.merge_git_command(
      git_dir,
      ["ls-tree", "-r", "-z", "--name-only", rev, "--"],
      strict_utf8=true,
    )
    if code == 0 {
      let all = output.split("\u{0}").filter(path => !path.is_empty()).collect()
      (
        all.iter().take(5000).map(path => path.to_owned()).collect(),
        all.length() >= 5000,
      )
    } else {
      ([], false)
    }
  } catch {
    _ => ([], true)
  }
  { refs, paths, truncated, }
}

///|
fn render_code_controls(
  repo : @domain.RepoId,
  rev : String,
  navigation : CodeNavigation,
  history~ : Bool = false,
) -> @moonback.Html {
  let base = @web_ui.repo_link(repo)
  Html(b => {
    b <+
      "<div class=\"code-navigation\"><details class=\"branch-picker\" data-dismissable><summary class=\"button-link secondary-button\"><span class=\"ui-icon\" data-icon=\"git-branch\" aria-hidden=\"true\"></span>\{navigation.refs.iter().find_first(item => item.0 == rev).map(item => item.1).unwrap_or(rev)}</summary><div class=\"branch-picker-panel\"><h3>Switch branches or tags</h3>"
    for (value, label) in navigation.refs {
      b <+
        "<a href=\"\{base}?rev=\{@web_context.url_escape_path(value)}\">\{label}</a>"
    }
    if navigation.refs.is_empty() {
      b <+
        "<p class=\"muted\">No branches or tags available. Browse the current revision.</p>"
    }
    b <+
      "</div></details><details class=\"file-finder\" data-dismissable data-file-finder><summary class=\"button-link secondary-button\">Go to file <kbd>t</kbd></summary><div class=\"file-finder-panel\"><label class=\"field\"><span>Find a file</span><input type=\"search\" data-file-query autocomplete=\"off\" placeholder=\"Search file paths…\"></label><p class=\"muted\" data-file-count role=\"status\">\{navigation.paths.length().to_string()} files indexed</p>"
    if navigation.truncated {
      b <+
        "<p class=\"settings-notice\">File index is limited to 5,000 paths and 2 MiB of Git output. Browse folders for other files.</p>"
    }
    b <+ "<ul class=\"file-finder-results\">"
    for path in navigation.paths {
      b <+
        "<li data-file-result><a href=\"\{base}/blob/\{@web_context.url_escape_path(rev)}/\{@web_context.url_escape_path(path)}\">\{path}</a></li>"
    }
    if navigation.paths.is_empty() {
      b <+ "<li>No indexed files. Browse the repository folders.</li>"
    }
    b <+ "</ul></div></details>"
    if history {
      b <+
        "<a class=\"button-link secondary-button\" href=\"\{base}/commits?rev=\{@web_context.url_escape_path(rev)}\">History</a>"
    }
    b <+ "</div>"
  })
}
