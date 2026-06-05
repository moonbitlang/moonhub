///|
fn layout(title : String, body : String) -> String {
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>" +
  html_escape(title) +
  "</title><style>" +
  "body{font:14px/1.45 -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;margin:0;color:#1f2328;background:#fff}" +
  "header{border-bottom:1px solid #d8dee4;padding:12px 24px;background:#f6f8fa}" +
  "main{max-width:1100px;margin:0 auto;padding:24px}" +
  "a{color:#0969da;text-decoration:none}a:hover{text-decoration:underline}" +
  "table{width:100%;border-collapse:collapse}td,th{padding:8px 10px;border-bottom:1px solid #d8dee4;text-align:left}" +
  ".muted{color:#57606a}.path{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}" +
  "pre{overflow:auto;border:1px solid #d8dee4;border-radius:6px;padding:16px;background:#f6f8fa}" +
  ".tabs a{margin-right:14px}.err{color:#cf222e}" +
  "</style></head><body><header><a href=\"/\">moonhub</a></header><main>" +
  body +
  "</main></body></html>"
}

///|
fn repo_link(repo : RepoId) -> String {
  "/" + repo.path()
}

///|
async fn render_index(root : String) -> String {
  let repos = list_repositories(root)
  let b = StringBuilder()
  b.write_string("<h1>Repositories</h1>")
  if repos.is_empty() {
    b.write_string("<p class=\"muted\">No repositories found under ")
    b.write_string(html_escape(root))
    b.write_string(".</p>")
  } else {
    b.write_string("<table><thead><tr><th>Repository</th></tr></thead><tbody>")
    for repo in repos {
      b.write_string("<tr><td><a href=\"")
      b.write_string(repo_link(repo))
      b.write_string("\">")
      b.write_string(html_escape(repo.path()))
      b.write_string("</a></td></tr>")
    }
    b.write_string("</tbody></table>")
  }
  layout("moonhub", b.to_string())
}

///|
fn render_repo_nav(repo : RepoId, rev : String) -> String {
  let base = repo_link(repo)
  "<h1 class=\"path\">" +
  html_escape(repo.path()) +
  "</h1><p class=\"tabs\"><a href=\"" +
  base +
  "\">Files</a><a href=\"" +
  base +
  "/commits?rev=" +
  html_escape(rev) +
  "\">Commits</a></p>"
}

///|
async fn render_tree(
  root : String,
  repo : RepoId,
  rev : String,
  path : String,
) -> String {
  let git_dir = repo.git_dir(root)
  let entries = list_tree(git_dir, rev, path)
  let base = repo_link(repo) + "/tree/" + url_escape_path(rev)
  let b = StringBuilder()
  b.write_string(render_repo_nav(repo, rev))
  b.write_string("<h2 class=\"path\">/")
  b.write_string(html_escape(path))
  b.write_string(
    "</h2><table><thead><tr><th>Name</th><th>Type</th><th>Size</th></tr></thead><tbody>",
  )
  if !path.is_empty() {
    b.write_string("<tr><td><a href=\"")
    b.write_string(base)
    b.write_string(
      "\">..</a></td><td class=\"muted\">parent</td><td></td></tr>",
    )
  }
  for entry in entries {
    let child = if path.is_empty() {
      entry.name
    } else {
      path + "/" + entry.name
    }
    let href = if entry.kind == "tree" {
      base + "/" + url_escape_path(child)
    } else {
      repo_link(repo) +
      "/blob/" +
      url_escape_path(rev) +
      "/" +
      url_escape_path(child)
    }
    b.write_string("<tr><td><a class=\"path\" href=\"")
    b.write_string(href)
    b.write_string("\">")
    b.write_string(html_escape(entry.name))
    b.write_string("</a></td><td>")
    b.write_string(html_escape(entry.kind))
    b.write_string("</td><td class=\"muted\">")
    b.write_string(html_escape(entry.size.unwrap_or("")))
    b.write_string("</td></tr>")
  }
  b.write_string("</tbody></table>")
  layout(repo.path(), b.to_string())
}

///|
async fn render_blob(
  root : String,
  repo : RepoId,
  rev : String,
  path : String,
) -> String {
  let content = read_blob(repo.git_dir(root), rev, path)
  let b = StringBuilder()
  b.write_string(render_repo_nav(repo, rev))
  b.write_string("<h2 class=\"path\">")
  b.write_string(html_escape(path))
  b.write_string("</h2><pre>")
  b.write_string(html_escape(content))
  b.write_string("</pre>")
  layout(repo.path() + ":" + path, b.to_string())
}

///|
async fn render_commits(root : String, repo : RepoId, rev : String) -> String {
  let commits = list_commits(repo.git_dir(root), rev)
  let b = StringBuilder()
  b.write_string(render_repo_nav(repo, rev))
  b.write_string(
    "<h2>Commits</h2><table><thead><tr><th>Commit</th><th>Subject</th><th>Author</th><th>Date</th></tr></thead><tbody>",
  )
  for commit in commits {
    b.write_string("<tr><td><a class=\"path\" href=\"")
    b.write_string(repo_link(repo) + "/commit/" + commit.hash)
    b.write_string("\">")
    b.write_string(html_escape(commit.hash[:12].to_owned()))
    b.write_string("</a></td><td>")
    b.write_string(html_escape(commit.subject))
    b.write_string("</td><td>")
    b.write_string(html_escape(commit.author))
    b.write_string("</td><td class=\"muted\">")
    b.write_string(html_escape(commit.date))
    b.write_string("</td></tr>")
  }
  b.write_string("</tbody></table>")
  layout(repo.path() + " commits", b.to_string())
}

///|
async fn render_commit(root : String, repo : RepoId, commit : String) -> String {
  let detail = commit_detail(repo.git_dir(root), commit)
  let b = StringBuilder()
  b.write_string(render_repo_nav(repo, commit))
  b.write_string("<h2 class=\"path\">")
  b.write_string(html_escape(commit))
  b.write_string("</h2><pre>")
  b.write_string(html_escape(detail))
  b.write_string("</pre>")
  layout(repo.path() + " " + commit, b.to_string())
}

///|
fn render_error(status : Int, message : String) -> String {
  layout(
    status.to_string() + " " + message,
    "<h1 class=\"err\">" + html_escape(message) + "</h1>",
  )
}
