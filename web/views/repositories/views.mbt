///|
fn render_index(
  repos~ : Array[@domain.RepoId],
  asset_path_map~ : Map[String, String],
  current_user~ : @domain.CurrentUser? = None,
  personal_owner~ : String? = None,
) -> @moonback.Html {
  @web_ui.layout(
    "moonhub",
    asset_path_map,
    Html(b => {
      b <+
        "<div class=\"page-heading page-heading--actions\"><div class=\"heading-title\"><h1>Repositories</h1><span class=\"count-badge\">\{repos.length().to_string()}</span></div><div class=\"heading-actions\">"
      if personal_owner is Some(owner) {
        b <+
          "<a class=\"button-link\" href=\"/\{owner}/-/repositories/new\"><span class=\"ui-icon\" data-icon=\"plus\" aria-hidden=\"true\"></span>New repository</a>"
      }
      b <+
        "<a class=\"secondary-button button-link\" href=\"/-/teams\"><span class=\"ui-icon\" data-icon=\"users\" aria-hidden=\"true\"></span>Browse teams</a></div></div>"
      if repos.is_empty() {
        b <+
          "<div class=\"empty-state\"><span class=\"empty-icon ui-icon\" data-icon=\"book-open\" aria-hidden=\"true\"></span><h2>No repositories yet</h2>"
        if personal_owner is Some(owner) {
          b <+
            "<a href=\"/\{owner}/-/repositories/new\">Create your first repository</a>"
        }
        b <+ "<a href=\"/-/teams\">Browse your teams</a></div>"
      } else {
        b <+
          "<section data-filter-list><div class=\"list-toolbar\"><label class=\"search-field\" hidden inert data-filter-control><span class=\"ui-icon\" data-icon=\"search\" aria-hidden=\"true\"></span><input type=\"search\" data-list-filter placeholder=\"Find a repository...\" aria-label=\"Find a repository\"></label><span class=\"list-total\" data-list-total>\{repos.length().to_string()} repositories</span></div><ul class=\"repository-list\">"
        for repo in repos {
          b <+
            "<li data-filter-item data-filter-text=\"\{repo.path()}\"><a class=\"repository-list-link\" href=\"\{@web_ui.repo_link(repo)}\"><span class=\"repository-icon\"><span class=\"ui-icon\" data-icon=\"book-open\" aria-hidden=\"true\"></span></span><span class=\"repository-identity\"><strong>\{repo.name}</strong><span>\{repo.path()}</span></span><span class=\"repository-owner\">\{repo.owner}</span><span class=\"ui-icon row-chevron\" data-icon=\"chevron-right\" aria-hidden=\"true\"></span></a></li>"
        }
        b <+
          "</ul><p class=\"filter-empty empty-state\" data-filter-empty hidden>No matching repositories.</p></section>"
      }
    }),
    current_user~,
  )
}

///|
fn escape_html_text_chunk(chunk : Bytes) -> Bytes {
  // Escape markup bytes without decoding UTF-8 split across stream chunks.
  let escaped : Array[Byte] = []
  for byte in chunk {
    match byte {
      b'&' => escaped.append(b"&amp;".to_array())
      b'<' => escaped.append(b"&lt;".to_array())
      b'>' => escaped.append(b"&gt;".to_array())
      _ => escaped.push(byte)
    }
  }
  Bytes::from_array(escaped)
}

///|
async fn stream_commit_detail(
  b : @moonback.HtmlBuilder,
  git_dir : String,
  commit : String,
  structured_view~ : @moonback.Html? = None,
) -> Unit {
  let args = @gitops.git_args(git_dir, [
    "show",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--format=medium",
    "--diff-algorithm=histogram",
    "--diff-merges=first-parent",
    if structured_view is Some(_) {
      "--no-patch"
    } else {
      "--patch"
    },
    "--find-renames",
    "--src-prefix=a/",
    "--dst-prefix=b/",
    "--date=iso-strict",
    commit,
    "--",
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
    b <+ "<pre>"
    let mut header = true
    for i, line in summary_text.split("\n").collect() {
      if i > 0 {
        b <+ "\n"
      }
      if line.is_empty() {
        header = false
      }
      if header && line.has_prefix("Date:") {
        b <+ "Date:   \{@web_ui.timestamp(line[5:].trim().to_owned())}"
      } else {
        b <+ "\{line.to_owned()}"
      }
    }
    b <+ "</pre><h2>Changes</h2>"
    if structured_view is Some(view) {
      b <+ "\{view}"
    } else if reader.read_some(max_len=8192) is Some(first_chunk) {
      let first_chunk = @moonback.Html::raw_utf8_chunk(
        escape_html_text_chunk(first_chunk),
      )
      b <+ "<moonhub-commit-diff><pre data-patch>diff --git \{first_chunk}"
      while reader.read_some(max_len=8192) is Some(chunk) {
        let chunk = @moonback.Html::raw_utf8_chunk(
          escape_html_text_chunk(chunk),
        )
        b <+ "\{chunk}"
      }
      b <+ "</pre></moonhub-commit-diff>"
    } else {
      b <+ "<p class=\"muted\">No file changes.</p>"
    }
    let _ = process.wait()
  })
}

///|
fn render_file_breadcrumbs(
  repo : @domain.RepoId,
  rev : String,
  path : String,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(repo)}/tree/\{@web_context.url_escape_path(rev)}"
  let items : Array[(String, String?)] = [
    ("Files", if path.is_empty() { None } else { Some(base) }),
  ]
  let mut ancestor = ""
  let segments = path
    .split("/")
    .filter(segment => !segment.is_empty())
    .collect()
  for i, segment in segments {
    ancestor = if ancestor.is_empty() {
      segment.to_owned()
    } else {
      "\{ancestor}/\{segment}"
    }
    let href = if i == segments.length() - 1 {
      None
    } else {
      Some("\{base}/\{@web_context.url_escape_path(ancestor)}")
    }
    items.push((segment.to_owned(), href))
  }
  @web_ui.render_breadcrumb_trail(items, label="File path", file_path=true)
}

///|
async fn render_tree(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : @domain.RepoId,
  rev~ : String,
  path~ : String,
  clone_url~ : String? = None,
  current_user~ : @domain.CurrentUser? = None,
  manager~ : Bool = false,
) -> @moonback.Html {
  let git_dir = repo.git_dir(root)
  let entries = @gitops.list_tree(git_dir, rev, path) catch {
    @gitops.GitCommandFailed(_) =>
      if path.is_empty() && @gitops.is_unborn_default_ref(git_dir, rev) {
        []
      } else {
        raise @domain.NotFound(message="tree not found")
      }
    err => raise err
  }
  let base = "\{@web_ui.repo_link(repo)}/tree/\{@web_context.url_escape_path(rev)}"
  @web_ui.layout(
    repo.path(),
    asset_path_map,
    Html(b => {
      b <+ "\{@web_ui.render_repo_nav(repo, rev, clone_url)}"
      b <+
        "<div class=\"content-stack\">\{render_file_breadcrumbs(repo, rev, path)}<div class=\"table-frame file-table\"><div class=\"table-scroll\"><table><thead><tr><th>Name</th><th class=\"numeric\" title=\"Bytes\">Size</th></tr></thead><tbody>"
      if !path.is_empty() {
        let parent = match path.rev_find("/") {
          Some(index) =>
            "\{base}/\{@web_context.url_escape_path(path[:index].to_owned())}"
          None => base
        }
        b <+
          "<tr><td><a href=\"\{parent}\" aria-label=\"Parent directory\">..</a></td><td></td></tr>"
      }
      for entry in entries {
        let child = if path.is_empty() {
          entry.name
        } else {
          "\{path}/\{entry.name}"
        }
        let child_url = @web_context.url_escape_path(child)
        let href = if entry.kind == "tree" {
          "\{base}/\{child_url}"
        } else {
          "\{@web_ui.repo_link(repo)}/blob/\{@web_context.url_escape_path(rev)}/\{child_url}"
        }
        let entry_size = entry.size.unwrap_or("-")
        b <+
          "<tr><td><a class=\"file-link\" href=\"\{href}\"><span class=\"ui-icon\" data-icon=\"\{if entry.kind == "tree" { "folder" } else { "file" }}\" aria-hidden=\"true\"></span>\{entry.name}</a></td><td class=\"muted numeric\">\{entry_size}</td></tr>"
      }
      if entries.is_empty() {
        b <+ "<tr><td colspan=\"2\" class=\"muted\">No files.</td></tr>"
      }
      b <+ "</tbody></table></div></div></div>"
    }),
    head_end=@web_assets.repository_assets_head(asset_path_map),
    current_user~,
    navigation=@web_ui.RepositoryNavigation(repo, "files", manager),
  )
}

///|
async fn render_blob(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : @domain.RepoId,
  rev~ : String,
  path~ : String,
  clone_url~ : String? = None,
  current_user~ : @domain.CurrentUser? = None,
  manager~ : Bool = false,
) -> @moonback.Html {
  let content = @gitops.read_blob(repo.git_dir(root), rev, path) catch {
    @gitops.GitCommandFailed(_) =>
      raise @domain.NotFound(message="file not found")
    err => raise err
  }
  @web_ui.layout(
    "\{repo.path()}:\{path}",
    asset_path_map,
    Html(b => {
      b <+ "\{@web_ui.render_repo_nav(repo, rev, clone_url)}"
      b <+
        "\{render_file_breadcrumbs(repo, rev, path)}<moonhub-file-view><span data-file-name hidden>\{path}</span><pre data-file-content>\{content}</pre></moonhub-file-view>"
    }),
    head_end=@web_assets.repository_assets_head(asset_path_map, code_view=true),
    current_user~,
    navigation=@web_ui.RepositoryNavigation(repo, "files", manager),
  )
}

///|
async fn render_commits(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : @domain.RepoId,
  rev~ : String,
  clone_url~ : String? = None,
  current_user~ : @domain.CurrentUser? = None,
  manager~ : Bool = false,
) -> @moonback.Html {
  let commits = @gitops.list_commits(repo.git_dir(root), rev) catch {
    @gitops.GitCommandFailed(_) =>
      if @gitops.is_unborn_default_ref(repo.git_dir(root), rev) {
        []
      } else {
        raise @domain.NotFound(message="commit not found")
      }
    err => raise err
  }
  @web_ui.layout(
    "\{repo.path()} commits",
    asset_path_map,
    Html(b => {
      b <+ "\{@web_ui.render_repo_nav(repo, rev, clone_url)}"
      b <+
        "<div class=\"content-stack\"><h2>Commits</h2><div class=\"table-frame\"><div class=\"table-scroll\"><table><thead><tr><th>Commit</th><th>Subject</th><th>Author</th><th>Date</th></tr></thead><tbody>"
      for commit in commits {
        let href = "\{@web_ui.repo_link(repo)}/commit/\{commit.hash}"
        let short_hash = commit.hash[:12].to_owned()
        b <+
          "<tr><td><a class=\"path\" href=\"\{href}\">\{short_hash}</a></td><td>\{commit.subject}</td><td>\{commit.author}</td><td class=\"muted\">\{commit.date}</td></tr>"
      }
      if commits.is_empty() {
        b <+ "<tr><td colspan=\"4\" class=\"muted\">No commits.</td></tr>"
      }
      b <+ "</tbody></table></div></div></div>"
    }),
    head_end=@web_assets.repository_assets_head(asset_path_map),
    current_user~,
    navigation=@web_ui.RepositoryNavigation(repo, "commits", manager),
  )
}

///|
async fn render_commit(
  diff_view~ : @moonback.Html? = None,
  diff_toolbar~ : @moonback.Html? = None,
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : @domain.RepoId,
  commit~ : String,
  current_user~ : @domain.CurrentUser? = None,
  manager~ : Bool = false,
) -> @moonback.Html {
  let git_dir = repo.git_dir(root)
  let _ = @gitops.run_git(git_dir, ["cat-file", "-e", "\{commit}^{commit}"]) catch {
    @gitops.GitCommandFailed(_) =>
      raise @domain.NotFound(message="commit not found")
    err => raise err
  }
  @web_ui.layout(
    "\{repo.path()} \{commit}",
    asset_path_map,
    Html(b => {
      if diff_toolbar is Some(_) {
        b <+
          "<button class=\"icon-button mobile-menu-button diff-navigation\" type=\"button\" data-sidebar-open aria-label=\"Open navigation\" title=\"Open navigation\" aria-controls=\"app-sidebar\" aria-expanded=\"false\" hidden inert><span class=\"ui-icon\" data-icon=\"menu\" aria-hidden=\"true\"></span></button>"
      }
      stream_commit_detail(b, git_dir, commit, structured_view=diff_view)
    }),
    head_end=@web_assets.repository_assets_head(asset_path_map, code_view=true),
    header_content=diff_toolbar,
    current_user~,
    navigation=@web_ui.RepositoryNavigation(repo, "commits", manager),
  )
}
