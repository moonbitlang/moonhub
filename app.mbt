///|
extenum @moonback.TypedBox += {
  RepoRoot(String)
  AssetsRoot(String)
}

///|
let config_root : @moonback.TypedKey[String] = TypedKey(
  name="moonhub.root",
  box=root => RepoRoot(root),
  unbox=err => {
    match err {
      RepoRoot(root) => Some(root)
      _ => None
    }
  },
)

///|
let config_assets_root : @moonback.TypedKey[String] = TypedKey(
  name="moonhub.assets_root",
  box=root => AssetsRoot(root),
  unbox=err => {
    match err {
      AssetsRoot(root) => Some(root)
      _ => None
    }
  },
)

///|
let app_module : @moonback.Module = Module(ctx => {
  ctx.add_middleware(app_error_middleware())
  let assets_app = @moonback.App(assets_module, config=ctx.config())
  ctx.mount("/\{public_assets_owner}", assets_app)
  ctx.use_(index_module)
  ctx.use_(repo_browser_module)
})

///|
let assets_module : @moonback.Module = Module(ctx => {
  ctx.add_middleware(static_assets(root=assets_root(ctx)))
})

///|
fn repo_root(ctx : @moonback.ModuleContext) -> String {
  match ctx.config().get_custom(config_root) {
    Some(root) => root
    None => abort("missing moonhub root")
  }
}

///|
fn assets_root(ctx : @moonback.ModuleContext) -> String {
  match ctx.config().get_custom(config_assets_root) {
    Some(root) => root
    None => abort("missing moonhub assets root")
  }
}

///|
let index_module : @moonback.Module = Module(ctx => {
  let root = repo_root(ctx)
  ctx.get("/", async fn(_req, res) { res.send_html(render_index(root)) })
})

///|
let repo_browser_module : @moonback.Module = Module(ctx => {
  let root = repo_root(ctx)
  let assets_root = assets_root(ctx)
  ctx.get("/:owner/:repo", async fn(req, res) {
    let repo = resolve_repo(root, req.repo_param())
    let git_dir = repo.git_dir(root)
    let rev = resolve_ref(git_dir, req.query_rev())
    res.send_html(render_tree(root, repo, rev, ""))
  })
  ctx.get("/:owner/:repo/tree", async fn(req, res) {
    let repo = resolve_repo(root, req.repo_param())
    let git_dir = repo.git_dir(root)
    let rev = resolve_ref(git_dir, None)
    res.send_html(render_tree(root, repo, rev, ""))
  })
  ctx.get("/:owner/:repo/tree/:rev", async fn(req, res) {
    let repo = resolve_repo(root, req.repo_param())
    let git_dir = repo.git_dir(root)
    let rev = resolve_ref(git_dir, Some(req.rev_param()))
    res.send_html(render_tree(root, repo, rev, ""))
  })
  ctx.get("/:owner/:repo/tree/:rev/*path", async fn(req, res) {
    let repo = resolve_repo(root, req.repo_param())
    let git_dir = repo.git_dir(root)
    let rev = resolve_ref(git_dir, Some(req.rev_param()))
    let path = req.path_param()
    res.send_html(render_tree(root, repo, rev, path))
  })
  ctx.get("/:owner/:repo/blob", async fn(req, _res) {
    let _ = resolve_repo(root, req.repo_param())
    raise NotFound(message="file not found")
  })
  ctx.get("/:owner/:repo/blob/:rev", async fn(req, _res) {
    let _ = resolve_repo(root, req.repo_param())
    let _ = req.rev_param()
    raise NotFound(message="file not found")
  })
  ctx.get("/:owner/:repo/blob/:rev/*path", async fn(req, res) {
    let repo = resolve_repo(root, req.repo_param())
    let rev = resolve_ref(repo.git_dir(root), Some(req.rev_param()))
    let path = req.path_param()
    if path.is_empty() {
      raise NotFound(message="file not found")
    } else {
      res.send_html(render_blob(root, assets_root, repo, rev, path))
    }
  })
  ctx.get("/:owner/:repo/commits", async fn(req, res) {
    let repo = resolve_repo(root, req.repo_param())
    let rev = resolve_ref(repo.git_dir(root), req.query_rev())
    res.send_html(render_commits(root, repo, rev))
  })
  ctx.get("/:owner/:repo/commit", async fn(req, _res) {
    let _ = resolve_repo(root, req.repo_param())
    raise NotFound(message="commit not found")
  })
  ctx.get("/:owner/:repo/commit/:commit", async fn(req, res) {
    let repo = resolve_repo(root, req.repo_param())
    let commit = req.commit_param()
    res.send_html(render_commit(root, assets_root, repo, commit))
  })
  ctx.get("/:owner/:repo/*path", async fn(req, _res) {
    let _ = resolve_repo(root, req.repo_param())
    raise NotFound(message="not found")
  })
})

///|
async fn resolve_repo(root : String, repo : RepoId) -> RepoId {
  guard repo_exists(root, repo) else {
    raise NotFound(message="repository not found")
  }
  repo
}
