///|
pub let index_module : @moonback.Module = Module(ctx => {
  let asset_path_map = ctx.require(@web_context.asset_paths_key)
  let access = ctx.require(@web_context.browser_access_key)
  let repositories = access.repositories
  let personal_owner = access.personal_owner
  ctx.get("/", async fn(req, res) {
    res.send_html(
      render_index(
        repos=repositories(req),
        asset_path_map~,
        current_user=@web_context.current_user_from_request(req),
        personal_owner=personal_owner(req),
      ),
    )
  })
})

///|
pub let repo_browser_module : @moonback.Module = Module(ctx => {
  let asset_path_map = ctx.require(@web_context.asset_paths_key)
  let access = ctx.require(@web_context.browser_access_key)
  let clone_url = access.clone_url
  let manager = access.manager
  let root = ctx.require(@web_context.config_root)
  let pool = ctx.require(@web_context.config_db_pool)
  let diff_executor = ctx.require(@web_context.diff_executor_key)
  let diff_enabled = ctx.require(@web_context.diff_enabled_key)
  let release_service = ctx.require(@web_context.release_service_key)
  let read_scope = req => {
    @repository.readable_repository_scope(
      pool,
      @web_context.current_user_from_request(req),
      @web_context.repo_param(req),
    )
  }
  let open_repo = async fn(req : @moonback.Request) {
    let scope = read_scope(req)
    let (reader, git_dir) = @repository.open_repository_read(
      pool,
      root,
      @web_context.current_user_from_request(req),
      scope,
    )
    (scope.repo, reader, git_dir)
  }
  let respond_page = async fn(
    req : @moonback.Request,
    res : @moonback.Responder,
    render : async (@domain.RepoId, String) -> @moonback.Html,
  ) {
    let page = {
      let (repo, reader, git_dir) = open_repo(req)
      defer reader.close()
      let page = render(repo, git_dir)
      ignore(read_scope(req))
      page
    }
    res.send_html(page)
  }
  ctx.get("/:owner/:repo", async fn(req, res) {
    respond_page(req, res, (repo, git_dir) => {
      let rev = @gitops.resolve_ref(git_dir, @web_context.query_rev(req))
      render_tree(
        pool~,
        release_service~,
        git_dir~,
        asset_path_map~,
        repo~,
        rev~,
        path="",
        clone_url=clone_url(repo),
        current_user=@web_context.current_user_from_request(req),
        manager=manager(req, repo),
      )
    })
  })
  ctx.get("/:owner/:repo/tree", async fn(req, res) {
    respond_page(req, res, (repo, git_dir) => {
      let rev = @gitops.resolve_ref(git_dir, None)
      render_tree(
        pool~,
        release_service~,
        git_dir~,
        asset_path_map~,
        repo~,
        rev~,
        path="",
        clone_url=clone_url(repo),
        current_user=@web_context.current_user_from_request(req),
        manager=manager(req, repo),
      )
    })
  })
  ctx.get("/:owner/:repo/tree/:rev", async fn(req, res) {
    respond_page(req, res, (repo, git_dir) => {
      let rev = @gitops.resolve_ref(git_dir, Some(@web_context.rev_param(req)))
      render_tree(
        pool~,
        release_service~,
        git_dir~,
        asset_path_map~,
        repo~,
        rev~,
        path="",
        clone_url=clone_url(repo),
        current_user=@web_context.current_user_from_request(req),
        manager=manager(req, repo),
      )
    })
  })
  ctx.get("/:owner/:repo/tree/:rev/*path", async fn(req, res) {
    respond_page(req, res, (repo, git_dir) => {
      let (rev, path) = @gitops.resolve_ref_path(
        git_dir,
        @web_context.rev_param(req),
        @web_context.path_param(req),
      )
      render_tree(
        pool~,
        release_service~,
        git_dir~,
        asset_path_map~,
        repo~,
        rev~,
        path~,
        clone_url=clone_url(repo),
        current_user=@web_context.current_user_from_request(req),
        manager=manager(req, repo),
      )
    })
  })
  ctx.get("/:owner/:repo/blob", (req, _res) => {
    ignore(read_scope(req))
    raise @domain.NotFound(message="file not found")
  })
  ctx.get("/:owner/:repo/blob/:rev", (req, _res) => {
    ignore(read_scope(req))
    let _ = @web_context.rev_param(req)
    raise @domain.NotFound(message="file not found")
  })
  ctx.get("/:owner/:repo/blob/:rev/*path", async fn(req, res) {
    respond_page(req, res, (repo, git_dir) => {
      let (rev, path) = @gitops.resolve_ref_path(
        git_dir,
        @web_context.rev_param(req),
        @web_context.path_param(req),
      )
      guard !path.is_empty() else {
        raise @domain.NotFound(message="file not found")
      }
      render_blob(
        git_dir~,
        asset_path_map~,
        repo~,
        rev~,
        path~,
        clone_url=clone_url(repo),
        current_user=@web_context.current_user_from_request(req),
        manager=manager(req, repo),
      )
    })
  })
  ctx.get("/:owner/:repo/commits", async fn(req, res) {
    respond_page(req, res, (repo, git_dir) => {
      let rev = @gitops.resolve_ref(git_dir, @web_context.query_rev(req))
      render_commits(
        git_dir~,
        asset_path_map~,
        repo~,
        rev~,
        current_user=@web_context.current_user_from_request(req),
        clone_url=clone_url(repo),
        manager=manager(req, repo),
      )
    })
  })
  ctx.get("/:owner/:repo/commit", (req, _res) => {
    ignore(read_scope(req))
    raise @domain.NotFound(message="commit not found")
  })
  ctx.get("/:owner/:repo/commit/:commit/diff", async fn(req, res) {
    let (_, reader, dir) = open_repo(req)
    defer reader.close()
    let (base, head) = @gitops.commit_comparison(
      dir,
      @web_context.commit_param(req),
    )
    let result = diff_executor.structured(
      dir,
      base,
      head,
      @web_context.structured_diff_options(req),
      page=@web_context.diff_page(req),
      file_id=req.query().get("file_id").unwrap_or(""),
    )
    ignore(read_scope(req))
    reader.close()
    res.send_json(result, headers={ "Cache-Control": "no-store" })
  })
  ctx.get("/:owner/:repo/commit/:commit", async fn(req, res) {
    let (repo, reader, git_dir) = open_repo(req)
    defer reader.close()
    let commit = @web_context.commit_param(req)
    let (diff_view, diff_toolbar) = if diff_enabled {
      let (base, head) = @gitops.commit_comparison(git_dir, commit)
      let options = @web_context.structured_diff_options(req)
      let manifest = diff_executor.manifest(
        git_dir,
        base,
        head,
        page=@web_context.diff_page(req),
      )
      let selected = match
        req.query().get("file_id").filter(id => !id.is_empty()) {
        Some(id) => Some(diff_executor.file(git_dir, manifest, id, options))
        None => None
      }
      ignore(read_scope(req))
      let url = "\{@web_ui.repo_link(repo)}/commit/\{head}"
      let view_url = url +
        "?fixed=1&page=\{manifest.page}" +
        selected.map(file => "&file_id=\{file.file.id}").unwrap_or("")
      (
        Some(
          @web_ui.render_structured_diff(
            manifest,
            selected,
            options,
            url + "/diff?fixed=1",
            url + "?fixed=1",
            view_url~,
            toolbar_target="commit-diff-toolbar",
          ),
        ),
        Some(
          @moonback.Html(b => {
            b <+
              "<moonhub-diff-toolbar id=\"commit-diff-toolbar\"><div data-toolbar-fallback>\{@web_ui.render_diff_options(options, view_url)}</div></moonhub-diff-toolbar>"
          }),
        ),
      )
    } else {
      (None, None)
    }
    let page = render_commit(
      git_dir~,
      asset_path_map~,
      repo~,
      commit~,
      diff_view~,
      diff_toolbar~,
      current_user=@web_context.current_user_from_request(req),
      manager=manager(req, repo),
    )
    ignore(read_scope(req))
    // The commit body streams Git output directly; bound the reader's lifetime
    // even if the client stops consuming the response.
    @async.with_timeout(30000, () => res.send_html(page))
  })
  ctx.get("/:owner/:repo/*path", (req, _res) => {
    ignore(read_scope(req))
    raise @domain.NotFound(message="not found")
  })
})
