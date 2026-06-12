///|
fn layout(
  title : String,
  body : @moonback.Html,
  head_end? : @moonback.Html = @moonback.Html::raw(""),
) -> @moonback.Html {
  @moonback.Html(b => {
    b <+
      $|<!doctype html><html><head><meta charset="utf-8"><title>\{title}</title><style>
      $|body{font:14px/1.45 -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;margin:0;color:#1f2328;background:#fff}
      $|header{border-bottom:1px solid #d8dee4;padding:12px 24px;background:#f6f8fa}
      $|main{max-width:1100px;margin:0 auto;padding:24px}
      $|a{color:#0969da;text-decoration:none}a:hover{text-decoration:underline}
      $|table{width:100%;border-collapse:collapse}td,th{padding:8px 10px;border-bottom:1px solid #d8dee4;text-align:left}
      $|.muted{color:#57606a}.path{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
      $|pre{overflow:auto;border:1px solid #d8dee4;border-radius:6px;padding:16px;background:#f6f8fa}
      $|moonhub-commit-diff,moonhub-file-view{display:block;margin-top:16px}
      $|moonhub-commit-diff pre[hidden],moonhub-file-view pre[hidden],moonhub-file-view [hidden]{display:none}
      $|.tabs a{margin-right:14px}.err{color:#cf222e}
      $|</style>\{head_end}</head><body><header><a href="/">moonhub</a></header><main>\{body}</main></body></html>
  })
}

///|
fn repo_link(repo : RepoId) -> String {
  "/\{repo.path()}"
}

///|
async fn render_index(root : String) -> @moonback.Html {
  let repos = list_repositories(root)
  layout(
    "moonhub",
    @moonback.Html(b => {
      b <+ "<h1>Repositories</h1>"
      if repos.is_empty() {
        b <+ "<p class=\"muted\">No repositories found under \{(root)}.</p>"
      } else {
        b <+ "<table><thead><tr><th>Repository</th></tr></thead><tbody>"
        for repo in repos {
          b <+
            "<tr><td><a href=\"\{repo_link(repo)}\">\{repo.path()}</a></td></tr>"
        }
        b <+ "</tbody></table>"
      }
    }),
  )
}

///|
fn render_repo_nav(repo : RepoId, rev : String) -> @moonback.Html {
  @moonback.Html(b => {
    let base = repo_link(repo)
    b <+
      "<h1 class=\"path\">\{repo.path()}</h1><p class=\"tabs\"><a href=\"\{base}\">Files</a><a href=\"\{base}/commits?rev=\{rev}\">Commits</a></p>"
  })
}

///|
async fn stream_commit_detail(
  b : @moonback.HtmlBuilder,
  git_dir : String,
  commit : String,
) -> Unit {
  let args = git_args(git_dir, [
    "show", "--diff-algorithm=histogram", "--patch", "--find-renames", "--date=iso-strict",
    commit,
  ])
  @async.with_task_group(group => {
    let (reader, writer) = @process.read_from_process()
    defer reader.close()
    let process = @process.spawn(
      group,
      "git",
      args,
      stdout=writer,
      stderr=writer,
    )
    let summary_text = match reader.read_until("\ndiff --git ") {
      Some(summary) => summary.trim().to_owned()
      None => ""
    }
    b <+ "<pre>\{summary_text}</pre>"
    if reader.read_some(max_len=8192) is Some(first_chunk) {
      let first_chunk = @moonback.Html::raw_utf8_chunk(first_chunk)
      b <+ "<moonhub-commit-diff><pre data-patch>diff --git \{first_chunk}"
      while reader.read_some(max_len=8192) is Some(chunk) {
        let chunk = @moonback.Html::raw_utf8_chunk(chunk)
        b <+ "\{chunk}"
      }
      b <+ "</pre></moonhub-commit-diff>"
    }
    ignore(process.wait())
  })
}

///|
async fn render_tree(
  root : String,
  repo : RepoId,
  rev : String,
  path : String,
) -> @moonback.Html {
  let git_dir = repo.git_dir(root)
  let entries = list_tree(git_dir, rev, path) catch {
    GitCommandFailed(_) => raise NotFound(message="tree not found")
    err => raise err
  }
  let base = "\{repo_link(repo)}/tree/\{url_escape_path(rev)}"
  layout(
    repo.path(),
    @moonback.Html(b => {
      b <+ "\{render_repo_nav(repo, rev)}"
      b <+
        "<h2 class=\"path\">/\{path}</h2><table><thead><tr><th>Name</th><th>Type</th><th>Size</th></tr></thead><tbody>"
      if !path.is_empty() {
        b <+
          "<tr><td><a href=\"\{base}\">..</a></td><td class=\"muted\">parent</td><td></td></tr>"
      }
      for entry in entries {
        let child = if path.is_empty() {
          entry.name
        } else {
          "\{path}/\{entry.name}"
        }
        let child_url = url_escape_path(child)
        let href = if entry.kind == "tree" {
          "\{base}/\{child_url}"
        } else {
          "\{repo_link(repo)}/blob/\{url_escape_path(rev)}/\{child_url}"
        }
        let entry_size = entry.size.unwrap_or("")
        b <+
          "<tr><td><a class=\"path\" href=\"\{href}\">\{entry.name}</a></td><td>\{entry.kind}</td><td class=\"muted\">\{entry_size}</td></tr>"
      }
      b <+ "</tbody></table>"
    }),
  )
}

///|
async fn render_blob(
  root : String,
  assets_root : String,
  repo : RepoId,
  rev : String,
  path : String,
) -> @moonback.Html {
  let content = read_blob(repo.git_dir(root), rev, path) catch {
    GitCommandFailed(_) => raise NotFound(message="file not found")
    err => raise err
  }
  layout(
    "\{repo.path()}:\{path}",
    @moonback.Html(b => {
      b <+ "\{render_repo_nav(repo, rev)}"
      b <+
        "<h2 class=\"path\">\{path}</h2><moonhub-file-view><span data-file-name hidden>\{path}</span><pre data-file-content>\{content}</pre></moonhub-file-view>"
    }),
    head_end=custom_elements_head(assets_root),
  )
}

///|
async fn render_commits(
  root : String,
  repo : RepoId,
  rev : String,
) -> @moonback.Html {
  let commits = list_commits(repo.git_dir(root), rev) catch {
    GitCommandFailed(_) => raise NotFound(message="commit not found")
    err => raise err
  }
  layout(
    "\{repo.path()} commits",
    @moonback.Html(b => {
      b <+ "\{render_repo_nav(repo, rev)}"
      b <+
        "<h2>Commits</h2><table><thead><tr><th>Commit</th><th>Subject</th><th>Author</th><th>Date</th></tr></thead><tbody>"
      for commit in commits {
        let href = "\{repo_link(repo)}/commit/\{commit.hash}"
        let short_hash = commit.hash[:12].to_owned()
        b <+
          "<tr><td><a class=\"path\" href=\"\{href}\">\{short_hash}</a></td><td>\{commit.subject}</td><td>\{commit.author}</td><td class=\"muted\">\{commit.date}</td></tr>"
      }
      b <+ "</tbody></table>"
    }),
  )
}

///|
async fn render_commit(
  root : String,
  assets_root : String,
  repo : RepoId,
  commit : String,
) -> @moonback.Html {
  let git_dir = repo.git_dir(root)
  let _ = run_git(git_dir, ["cat-file", "-e", "\{commit}^{commit}"]) catch {
    GitCommandFailed(_) => raise NotFound(message="commit not found")
    err => raise err
  }
  layout(
    "\{repo.path()} \{commit}",
    @moonback.Html(b => {
      b <+ "\{render_repo_nav(repo, commit)}"
      b <+ "<h2 class=\"path\">\{commit}</h2>"
      stream_commit_detail(b, git_dir, commit)
    }),
    head_end=custom_elements_head(assets_root),
  )
}

///|
fn render_error(status : Int, message : String) -> @moonback.Html {
  layout(
    "\{status} \{message}",
    @moonback.Html(b => b <+ "<h1 class=\"err\">\{message}</h1>"),
  )
}
