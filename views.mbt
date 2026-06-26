///|
fn layout(
  title : String,
  asset_path_map : Map[String, String],
  body : @moonback.Html,
  head_end? : @moonback.Html = @moonback.Html::raw(""),
) -> @moonback.Html {
  let stylesheet_head = app_styles_head(asset_path_map)
  Html(b => {
    b <+
      $|<!doctype html><html><head><meta charset="utf-8"><title>\{title}</title>\{stylesheet_head}\{head_end}</head><body><header class="site-header"><div class="site-header__inner"><a class="brand" href="/">moonhub</a></div></header><main class="page">\{body}</main></body></html>
  })
}

///|
fn repo_link(repo : RepoId) -> String {
  "/\{repo.path()}"
}

///|
async fn render_index(
  root~ : String,
  asset_path_map~ : Map[String, String],
) -> @moonback.Html {
  let repos = list_repositories(root)
  layout(
    "moonhub",
    asset_path_map,
    Html(b => {
      b <+ "<div class=\"page-heading\"><h1>Repositories</h1></div>"
      if repos.is_empty() {
        b <+
          "<div class=\"empty-state\"><p class=\"muted\">No repositories found under \{(root)}.</p></div>"
      } else {
        b <+
          "<div class=\"table-frame\"><div class=\"table-scroll\"><table><thead><tr><th>Repository</th></tr></thead><tbody>"
        for repo in repos {
          b <+
            "<tr><td><a class=\"repo-name\" href=\"\{repo_link(repo)}\">\{repo.path()}</a></td></tr>"
        }
        b <+ "</tbody></table></div></div>"
      }
    }),
  )
}

///|
fn render_repo_nav(repo : RepoId, rev : String) -> @moonback.Html {
  Html(b => {
    let base = repo_link(repo)
    b <+
      "<div class=\"repo-header\"><h1 class=\"path repo-title\">\{repo.path()}</h1><p class=\"tabs\"><a href=\"\{base}\">Files</a><a href=\"\{base}/commits?rev=\{rev}\">Commits</a></p></div>"
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
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : RepoId,
  rev~ : String,
  path~ : String,
) -> @moonback.Html {
  let git_dir = repo.git_dir(root)
  let entries = list_tree(git_dir, rev, path) catch {
    GitCommandFailed(_) => raise NotFound(message="tree not found")
    err => raise err
  }
  let base = "\{repo_link(repo)}/tree/\{url_escape_path(rev)}"
  layout(
    repo.path(),
    asset_path_map,
    Html(b => {
      b <+ "\{render_repo_nav(repo, rev)}"
      b <+
        "<div class=\"content-stack\"><h2 class=\"path\">/\{path}</h2><div class=\"table-frame\"><div class=\"table-scroll\"><table><thead><tr><th>Name</th><th>Type</th><th>Size</th></tr></thead><tbody>"
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
      b <+ "</tbody></table></div></div></div>"
    }),
  )
}

///|
async fn render_blob(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : RepoId,
  rev~ : String,
  path~ : String,
) -> @moonback.Html {
  let content = read_blob(repo.git_dir(root), rev, path) catch {
    GitCommandFailed(_) => raise NotFound(message="file not found")
    err => raise err
  }
  layout(
    "\{repo.path()}:\{path}",
    asset_path_map,
    Html(b => {
      b <+ "\{render_repo_nav(repo, rev)}"
      b <+
        "<h2 class=\"path\">\{path}</h2><moonhub-file-view><span data-file-name hidden>\{path}</span><pre data-file-content>\{content}</pre></moonhub-file-view>"
    }),
    head_end=custom_elements_head(asset_path_map),
  )
}

///|
async fn render_commits(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : RepoId,
  rev~ : String,
) -> @moonback.Html {
  let commits = list_commits(repo.git_dir(root), rev) catch {
    GitCommandFailed(_) => raise NotFound(message="commit not found")
    err => raise err
  }
  layout(
    "\{repo.path()} commits",
    asset_path_map,
    Html(b => {
      b <+ "\{render_repo_nav(repo, rev)}"
      b <+
        "<div class=\"content-stack\"><h2>Commits</h2><div class=\"table-frame\"><div class=\"table-scroll\"><table><thead><tr><th>Commit</th><th>Subject</th><th>Author</th><th>Date</th></tr></thead><tbody>"
      for commit in commits {
        let href = "\{repo_link(repo)}/commit/\{commit.hash}"
        let short_hash = commit.hash[:12].to_owned()
        b <+
          "<tr><td><a class=\"path\" href=\"\{href}\">\{short_hash}</a></td><td>\{commit.subject}</td><td>\{commit.author}</td><td class=\"muted\">\{commit.date}</td></tr>"
      }
      b <+ "</tbody></table></div></div></div>"
    }),
  )
}

///|
async fn render_commit(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : RepoId,
  commit~ : String,
) -> @moonback.Html {
  let git_dir = repo.git_dir(root)
  let _ = run_git(git_dir, ["cat-file", "-e", "\{commit}^{commit}"]) catch {
    GitCommandFailed(_) => raise NotFound(message="commit not found")
    err => raise err
  }
  layout(
    "\{repo.path()} \{commit}",
    asset_path_map,
    Html(b => {
      b <+ "\{render_repo_nav(repo, commit)}"
      b <+ "<h2 class=\"path\">\{commit}</h2>"
      stream_commit_detail(b, git_dir, commit)
    }),
    head_end=custom_elements_head(asset_path_map),
  )
}

///|
fn render_error(
  status : Int,
  message : String,
  asset_path_map : Map[String, String],
) -> @moonback.Html {
  let status_text = status.to_string()
  layout(
    "\{status} \{message}",
    asset_path_map,
    Html(b => {
      b <+
        "<section class=\"error-page\"><p class=\"error-code\">\{status_text}</p><h1 class=\"err\">\{message}</h1></section>"
    }),
  )
}
