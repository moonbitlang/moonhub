///|
extenum @moonback.TypedBox += {
  RepoRoot(String)
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
let app_module : @moonback.Module = Module(ctx => {
  ctx.use_(index_module)
  ctx.use_(repo_browser_module)
})

///|
fn repo_root(ctx : @moonback.ModuleContext) -> String {
  match ctx.config().get_custom(config_root) {
    Some(root) => root
    None => abort("missing moonhub root")
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
  ctx.get("/:owner/:repo", async fn(req, res) {
    match repo_from_params(req) {
      None =>
        res.send_html(render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(root, repo) {
          res.send_html(render_error(404, "repository not found"), status=404)
        } else {
          let git_dir = repo.git_dir(root)
          let rev = resolve_ref(git_dir, query_rev(req))
          res.send_html(render_tree(root, repo, rev, ""))
        }
    }
  })
  ctx.get("/:owner/:repo/tree", async fn(req, res) {
    match repo_from_params(req) {
      None =>
        res.send_html(render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(root, repo) {
          res.send_html(render_error(404, "repository not found"), status=404)
        } else {
          let git_dir = repo.git_dir(root)
          let rev = resolve_ref(git_dir, None)
          res.send_html(render_tree(root, repo, rev, ""))
        }
    }
  })
  ctx.get("/:owner/:repo/tree/:rev", async fn(req, res) {
    match repo_from_params(req) {
      None =>
        res.send_html(render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(root, repo) {
          res.send_html(render_error(404, "repository not found"), status=404)
        } else {
          let git_dir = repo.git_dir(root)
          let rev = resolve_ref(git_dir, Some(param_value(req, "rev")))
          res.send_html(render_tree(root, repo, rev, ""))
        }
    }
  })
  ctx.get("/:owner/:repo/tree/:rev/*path", async fn(req, res) {
    match repo_from_params(req) {
      None =>
        res.send_html(render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(root, repo) {
          res.send_html(render_error(404, "repository not found"), status=404)
        } else {
          let git_dir = repo.git_dir(root)
          let rev = resolve_ref(git_dir, Some(param_value(req, "rev")))
          let path = param_value(req, "path")
          res.send_html(render_tree(root, repo, rev, path))
        }
    }
  })
  ctx.get("/:owner/:repo/blob", async fn(req, res) {
    match repo_from_params(req) {
      None =>
        res.send_html(render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(root, repo) {
          res.send_html(render_error(404, "repository not found"), status=404)
        } else {
          res.send_html(render_error(404, "file not found"), status=404)
        }
    }
  })
  ctx.get("/:owner/:repo/blob/:rev", async fn(req, res) {
    match repo_from_params(req) {
      None =>
        res.send_html(render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(root, repo) {
          res.send_html(render_error(404, "repository not found"), status=404)
        } else {
          res.send_html(render_error(404, "file not found"), status=404)
        }
    }
  })
  ctx.get("/:owner/:repo/blob/:rev/*path", async fn(req, res) {
    match repo_from_params(req) {
      None =>
        res.send_html(render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(root, repo) {
          res.send_html(render_error(404, "repository not found"), status=404)
        } else {
          let rev = resolve_ref(
            repo.git_dir(root),
            Some(param_value(req, "rev")),
          )
          let path = param_value(req, "path")
          if path.is_empty() {
            res.send_html(render_error(404, "file not found"), status=404)
          } else {
            res.send_html(render_blob(root, repo, rev, path))
          }
        }
    }
  })
  ctx.get("/:owner/:repo/commits", async fn(req, res) {
    match repo_from_params(req) {
      None =>
        res.send_html(render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(root, repo) {
          res.send_html(render_error(404, "repository not found"), status=404)
        } else {
          let rev = resolve_ref(repo.git_dir(root), query_rev(req))
          res.send_html(render_commits(root, repo, rev))
        }
    }
  })
  ctx.get("/:owner/:repo/commit", async fn(req, res) {
    match repo_from_params(req) {
      None =>
        res.send_html(render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(root, repo) {
          res.send_html(render_error(404, "repository not found"), status=404)
        } else {
          res.send_html(render_error(404, "commit not found"), status=404)
        }
    }
  })
  ctx.get("/:owner/:repo/commit/:commit", async fn(req, res) {
    match repo_from_params(req) {
      None =>
        res.send_html(render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(root, repo) {
          res.send_html(render_error(404, "repository not found"), status=404)
        } else {
          let commit = param_value(req, "commit")
          if valid_segment(commit) {
            res.send_html(render_commit(root, repo, commit))
          } else {
            res.send_html(render_error(404, "commit not found"), status=404)
          }
        }
    }
  })
  ctx.get("/:owner/:repo/*path", async fn(req, res) {
    match repo_from_params(req) {
      None =>
        res.send_html(render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(root, repo) {
          res.send_html(render_error(404, "repository not found"), status=404)
        } else {
          res.send_html(render_error(404, "not found"), status=404)
        }
    }
  })
})

///|
fn query_rev(req : @moonback.Request) -> String? {
  req.query().get("rev")
}

///|
fn param_value(req : @moonback.Request, name : String) -> String {
  req.params[name].to_owned()
}

///|
fn repo_from_params(req : @moonback.Request) -> RepoId? {
  let owner = param_value(req, "owner")
  let name = param_value(req, "repo")
  if valid_segment(owner) && valid_segment(name) {
    Some({ owner, name })
  } else {
    None
  }
}
