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
  let config = ctx.config()
  ctx.mount("/\{PUBLIC_ASSETS_OWNER}", App(assets_module, config~))
  ctx.mount("/", App(app_main_module, config~))
})

///|
let app_main_module : @moonback.Module = Module(ctx => {
  let asset_path_map = load_entry_to_asset_path_map(assets_root(ctx))
  let pool = db_pool(ctx)
  ctx.add_middleware(app_error_middleware(asset_path_map))
  ctx.add_middleware(auth_middleware(pool))
  ctx.add_middleware(require_login_middleware())
  ctx.use_(auth_module(asset_path_map))
  ctx.use_(ssh_keys_module(asset_path_map))
  ctx.use_(site_settings_module(asset_path_map))
  let root = repo_root(ctx)
  ctx.use_(
    index_module(asset_path_map, req => {
      visible_repositories(pool, root, require_current_user(req))
    }),
  )
  ctx.use_(teams_module(asset_path_map))
  ctx.use_(repositories_module(asset_path_map))
  ctx.use_(merge_requests_module(asset_path_map))
  ctx.use_(issues_module(asset_path_map))
  ctx.use_(
    repo_browser_module(
      asset_path_map,
      (req, repo) => {
        authorize_repository(pool, require_current_user(req), repo, Read)
      },
      clone_url=repo => {
        effective_ssh_endpoint(
          pool,
          ctx
          .config()
          .get_custom(config_ssh_addresses)
          .unwrap_or(no_ssh_address_config),
        ).map(endpoint => endpoint.clone_url(repo))
      },
      manager=(req, repo) => {
        match get_team_by_name_key(pool, repo.owner) {
          Some(team) =>
            can_manage_team(pool, require_current_user(req), team.id)
          None => false
        }
      },
    ),
  )
})

///|

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
fn index_module(
  asset_path_map : Map[String, String],
  repositories : async (@moonback.Request) -> Array[RepoId],
) -> @moonback.Module {
  Module(ctx => {
    ctx.get("/", async fn(req, res) {
      res.send_html(
        render_index(
          repos=repositories(req),
          asset_path_map~,
          current_user=current_user_from_request(req),
        ),
      )
    })
  })
}

///|
fn repo_browser_module(
  asset_path_map : Map[String, String],
  authorize : (@moonback.Request, RepoId) -> Unit raise,
  clone_url? : (RepoId) -> String? raise = _ => None,
  manager? : (@moonback.Request, RepoId) -> Bool raise = (_, _) => false,
) -> @moonback.Module {
  Module(ctx => {
    let root = repo_root(ctx)
    ctx.get("/:owner/:repo", async fn(req, res) {
      let repo = resolve_repo(root, req, authorize)
      let git_dir = repo.git_dir(root)
      let rev = resolve_ref(git_dir, req.query_rev())
      res.send_html(
        render_tree(
          root~,
          asset_path_map~,
          repo~,
          rev~,
          path="",
          clone_url=clone_url(repo),
          current_user=current_user_from_request(req),
          manager=manager(req, repo),
        ),
      )
    })
    ctx.get("/:owner/:repo/tree", async fn(req, res) {
      let repo = resolve_repo(root, req, authorize)
      let git_dir = repo.git_dir(root)
      let rev = resolve_ref(git_dir, None)
      res.send_html(
        render_tree(
          root~,
          asset_path_map~,
          repo~,
          rev~,
          path="",
          clone_url=clone_url(repo),
          current_user=current_user_from_request(req),
          manager=manager(req, repo),
        ),
      )
    })
    ctx.get("/:owner/:repo/tree/:rev", async fn(req, res) {
      let repo = resolve_repo(root, req, authorize)
      let git_dir = repo.git_dir(root)
      let rev = resolve_ref(git_dir, Some(req.rev_param()))
      res.send_html(
        render_tree(
          root~,
          asset_path_map~,
          repo~,
          rev~,
          path="",
          clone_url=clone_url(repo),
          current_user=current_user_from_request(req),
          manager=manager(req, repo),
        ),
      )
    })
    ctx.get("/:owner/:repo/tree/:rev/*path", async fn(req, res) {
      let repo = resolve_repo(root, req, authorize)
      let git_dir = repo.git_dir(root)
      let (rev, path) = resolve_ref_path(
        git_dir,
        req.rev_param(),
        req.path_param(),
      )
      res.send_html(
        render_tree(
          root~,
          asset_path_map~,
          repo~,
          rev~,
          path~,
          clone_url=clone_url(repo),
          current_user=current_user_from_request(req),
          manager=manager(req, repo),
        ),
      )
    })
    ctx.get("/:owner/:repo/blob", async fn(req, _res) {
      let _ = resolve_repo(root, req, authorize)
      raise NotFound(message="file not found")
    })
    ctx.get("/:owner/:repo/blob/:rev", async fn(req, _res) {
      let _ = resolve_repo(root, req, authorize)
      let _ = req.rev_param()
      raise NotFound(message="file not found")
    })
    ctx.get("/:owner/:repo/blob/:rev/*path", async fn(req, res) {
      let repo = resolve_repo(root, req, authorize)
      let (rev, path) = resolve_ref_path(
        repo.git_dir(root),
        req.rev_param(),
        req.path_param(),
      )
      if path.is_empty() {
        raise NotFound(message="file not found")
      } else {
        res.send_html(
          render_blob(
            root~,
            asset_path_map~,
            repo~,
            rev~,
            path~,
            clone_url=clone_url(repo),
            current_user=current_user_from_request(req),
            manager=manager(req, repo),
          ),
        )
      }
    })
    ctx.get("/:owner/:repo/commits", async fn(req, res) {
      let repo = resolve_repo(root, req, authorize)
      let rev = resolve_ref(repo.git_dir(root), req.query_rev())
      res.send_html(
        render_commits(
          root~,
          asset_path_map~,
          repo~,
          rev~,
          current_user=current_user_from_request(req),
          clone_url=clone_url(repo),
          manager=manager(req, repo),
        ),
      )
    })
    ctx.get("/:owner/:repo/commit", async fn(req, _res) {
      let _ = resolve_repo(root, req, authorize)
      raise NotFound(message="commit not found")
    })
    ctx.get("/:owner/:repo/commit/:commit", async fn(req, res) {
      let repo = resolve_repo(root, req, authorize)
      let commit = req.commit_param()
      res.send_html(
        render_commit(
          root~,
          asset_path_map~,
          repo~,
          commit~,
          clone_url=clone_url(repo),
          current_user=current_user_from_request(req),
          manager=manager(req, repo),
        ),
      )
    })
    ctx.get("/:owner/:repo/*path", async fn(req, _res) {
      let _ = resolve_repo(root, req, authorize)
      raise NotFound(message="not found")
    })
  })
}

///|
async fn resolve_repo(
  root : String,
  req : @moonback.Request,
  authorize : (@moonback.Request, RepoId) -> Unit raise,
) -> RepoId {
  let repo = req.repo_param()
  authorize(req, repo)
  let _ = resolve_repository_dir(root, repo)
  repo
}
