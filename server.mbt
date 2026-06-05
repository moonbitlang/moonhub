///|
async fn send_html(
  res : @moonback.Responder,
  html : String,
  status? : Int = 200,
) -> Unit {
  res.send_html(html, status~)
}

///|
fn query_rev(req : @moonback.Request) -> String? {
  req.query().get("rev")
}

///|
async fn handle(
  config : Config,
  req : @moonback.Request,
  res : @moonback.Responder,
) -> Unit {
  let parts = split_path(req.path)
  if parts.is_empty() {
    send_html(res, render_index(config.root))
  } else {
    match parse_repo_id(parts) {
      None =>
        send_html(res, render_error(404, "repository not found"), status=404)
      Some(repo) =>
        if !repo_exists(config.root, repo) {
          send_html(res, render_error(404, "repository not found"), status=404)
        } else {
          let git_dir = repo.git_dir(config.root)
          let action = parts.get(2).unwrap_or("")
          match action {
            "" => {
              let rev = resolve_ref(git_dir, query_rev(req))
              send_html(res, render_tree(config.root, repo, rev, ""))
            }
            "tree" => {
              let rev = match parts.get(3) {
                Some(v) => v
                None => default_ref(git_dir)
              }
              let path = rest_path(parts, from=4)
              send_html(res, render_tree(config.root, repo, rev, path))
            }
            "blob" => {
              let rev = match parts.get(3) {
                Some(v) => v
                None => default_ref(git_dir)
              }
              let path = rest_path(parts, from=4)
              if path.is_empty() {
                send_html(res, render_error(404, "file not found"), status=404)
              } else {
                send_html(res, render_blob(config.root, repo, rev, path))
              }
            }
            "commits" => {
              let rev = resolve_ref(git_dir, query_rev(req))
              send_html(res, render_commits(config.root, repo, rev))
            }
            "commit" =>
              match parts.get(3) {
                Some(commit) if valid_segment(commit) =>
                  send_html(res, render_commit(config.root, repo, commit))
                _ =>
                  send_html(
                    res,
                    render_error(404, "commit not found"),
                    status=404,
                  )
              }
            _ => send_html(res, render_error(404, "not found"), status=404)
          }
        }
    }
  }
}

///|
async fn serve(config : Config) -> Unit {
  @signal.set_global_cancellation_signals([@signal.SIGINT, @signal.SIGTERM])
  let root_module = @moonback.Module(fn(ctx) {
    ctx.get("/", async fn(req, res) { handle(config, req, res) }) catch {
      _ => ()
    }
    ctx.get("/*path", async fn(req, res) { handle(config, req, res) }) catch {
      _ => ()
    }
  })
  let app = @moonback.App(root_module)
  let listener = @moonback.listen(host=config.host, port=config.port)
  println(
    "moonhub serving " +
    config.root +
    " at http://" +
    config.host +
    ":" +
    config.port.to_string(),
  )
  app.serve(listener)
}
