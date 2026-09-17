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
  let authorize = access.authorize
  let clone_url = access.clone_url
  let manager = access.manager
  let root = ctx.require(@web_context.config_root)
  ctx.get("/:owner/:repo", async fn(req, res) {
    let repo = resolve_repo(root, req, authorize)
    let git_dir = repo.git_dir(root)
    let rev = @gitops.resolve_ref(git_dir, @web_context.query_rev(req))
    res.send_html(
      render_tree(
        root~,
        asset_path_map~,
        repo~,
        rev~,
        path="",
        clone_url=clone_url(repo),
        current_user=@web_context.current_user_from_request(req),
        manager=manager(req, repo),
      ),
    )
  })
  ctx.get("/:owner/:repo/tree", async fn(req, res) {
    let repo = resolve_repo(root, req, authorize)
    let git_dir = repo.git_dir(root)
    let rev = @gitops.resolve_ref(git_dir, None)
    res.send_html(
      render_tree(
        root~,
        asset_path_map~,
        repo~,
        rev~,
        path="",
        clone_url=clone_url(repo),
        current_user=@web_context.current_user_from_request(req),
        manager=manager(req, repo),
      ),
    )
  })
  ctx.get("/:owner/:repo/tree/:rev", async fn(req, res) {
    let repo = resolve_repo(root, req, authorize)
    let git_dir = repo.git_dir(root)
    let rev = @gitops.resolve_ref(git_dir, Some(@web_context.rev_param(req)))
    res.send_html(
      render_tree(
        root~,
        asset_path_map~,
        repo~,
        rev~,
        path="",
        clone_url=clone_url(repo),
        current_user=@web_context.current_user_from_request(req),
        manager=manager(req, repo),
      ),
    )
  })
  ctx.get("/:owner/:repo/tree/:rev/*path", async fn(req, res) {
    let repo = resolve_repo(root, req, authorize)
    let git_dir = repo.git_dir(root)
    let (rev, path) = @gitops.resolve_ref_path(
      git_dir,
      @web_context.rev_param(req),
      @web_context.path_param(req),
    )
    res.send_html(
      render_tree(
        root~,
        asset_path_map~,
        repo~,
        rev~,
        path~,
        clone_url=clone_url(repo),
        current_user=@web_context.current_user_from_request(req),
        manager=manager(req, repo),
      ),
    )
  })
  ctx.get("/:owner/:repo/blob", async fn(req, _res) {
    let _ = resolve_repo(root, req, authorize)
    raise @domain.NotFound(message="file not found")
  })
  ctx.get("/:owner/:repo/blob/:rev", async fn(req, _res) {
    let _ = resolve_repo(root, req, authorize)
    let _ = @web_context.rev_param(req)
    raise @domain.NotFound(message="file not found")
  })
  ctx.get("/:owner/:repo/blob/:rev/*path", async fn(req, res) {
    let repo = resolve_repo(root, req, authorize)
    let (rev, path) = @gitops.resolve_ref_path(
      repo.git_dir(root),
      @web_context.rev_param(req),
      @web_context.path_param(req),
    )
    if path.is_empty() {
      raise @domain.NotFound(message="file not found")
    } else {
      res.send_html(
        render_blob(
          root~,
          asset_path_map~,
          repo~,
          rev~,
          path~,
          clone_url=clone_url(repo),
          current_user=@web_context.current_user_from_request(req),
          manager=manager(req, repo),
        ),
      )
    }
  })
  ctx.get("/:owner/:repo/commits", async fn(req, res) {
    let repo = resolve_repo(root, req, authorize)
    let rev = @gitops.resolve_ref(
      repo.git_dir(root),
      @web_context.query_rev(req),
    )
    res.send_html(
      render_commits(
        root~,
        asset_path_map~,
        repo~,
        rev~,
        current_user=@web_context.current_user_from_request(req),
        clone_url=clone_url(repo),
        manager=manager(req, repo),
      ),
    )
  })
  ctx.get("/:owner/:repo/commit", async fn(req, _res) {
    let _ = resolve_repo(root, req, authorize)
    raise @domain.NotFound(message="commit not found")
  })
  ctx.get("/:owner/:repo/commit/:commit", async fn(req, res) {
    let repo = resolve_repo(root, req, authorize)
    let commit = @web_context.commit_param(req)
    res.send_html(
      render_commit(
        root~,
        asset_path_map~,
        repo~,
        commit~,
        clone_url=clone_url(repo),
        current_user=@web_context.current_user_from_request(req),
        manager=manager(req, repo),
      ),
    )
  })
  ctx.get("/:owner/:repo/*path", async fn(req, _res) {
    let _ = resolve_repo(root, req, authorize)
    raise @domain.NotFound(message="not found")
  })
})

///|
async fn resolve_repo(
  root : String,
  req : @moonback.Request,
  authorize : (@moonback.Request, @domain.RepoId) -> Unit raise,
) -> @domain.RepoId {
  let repo = @web_context.repo_param(req)
  authorize(req, repo)
  let _ = @repository.resolve_repository_dir(root, repo)
  repo
}
