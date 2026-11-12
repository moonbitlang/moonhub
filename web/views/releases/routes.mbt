///|
pub let releases_module : @moonback.Module = Module(ctx => {
  let service = ctx.require(@web_context.release_service_key)
  let assets = ctx.require(@web_context.asset_paths_key)
  let access_policy = ctx.require(@web_context.browser_access_key)
  let transfers = @async.Semaphore(2)
  ctx.get("/:owner/:repo/releases", async fn(req, res) {
    let repo = @web_context.repo_param(req)
    let user = @web_context.current_user_from_request(req)
    let releases = service.list(@release_store.access(repo, user))
    let manager = (access_policy.manager)(req, repo)
    res.send_html(
      @web_ui.layout(
        "Releases",
        assets,
        Html(b => {
          b <+
            "<div class=\"page-heading page-heading--actions\"><h1>Releases</h1>"
          if manager {
            b <+
              "<a class=\"button-link\" href=\"/\{repo.path()}/releases/new\">New release</a>"
          }
          b <+ "</div>"
          if releases.is_empty() {
            b <+
              "<div class=\"empty-state\"><h2>No releases yet</h2><p>Published versions and their downloadable assets will appear here.</p></div>"
          }
          for release in releases {
            b <+
              "<article class=\"release-row\"><div><h2><a href=\"/\{repo.path()}/releases/\{release.id.to_string()}\">\{release.title}</a></h2><p>\{release.tag} · <code class=\"release-digest\">\{release.commit_sha}</code></p></div><span class=\"status-badge\">\{if release.draft {"Draft"} else if release.prerelease {"Prerelease"} else {"Published"}}</span></article>"
          }
        }),
        current_user=user,
        navigation=RepositoryNavigation(repo, "releases", manager),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/:owner/:repo/releases/new", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    guard (access_policy.manager)(req, repo) else {
      raise @domain.Forbidden(message="repository manager required")
    }
    let csrf = @web_context.request_form_token(req, "releases:" + repo.path())
    res.send_html(
      @web_ui.layout(
        "New release",
        assets,
        Html(b => {
          b <+
            "<h1>New release</h1><p>Create a draft, upload its assets with the release API or CLI, then publish the version.</p><form method=\"post\" action=\"/\{repo.path()}/releases\" class=\"form-stack repository-form\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><label for=\"release-tag\">Version tag</label><input id=\"release-tag\" name=\"tag\" required maxlength=\"200\" placeholder=\"v1.0.0\"><label for=\"release-target\">Branch or commit</label><input id=\"release-target\" name=\"target\" required value=\"HEAD\"><label for=\"release-title\">Title</label><input id=\"release-title\" name=\"title\" required maxlength=\"1024\"><label for=\"release-notes\">Release notes</label><textarea id=\"release-notes\" name=\"body\" rows=\"8\"></textarea><button type=\"submit\">Create draft</button> <a href=\"/\{repo.path()}/releases\">Cancel</a></form>"
        }),
        current_user=Some(actor),
        navigation=RepositoryNavigation(repo, "releases", true),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/releases", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let form = @web_context.protected_form(req, "releases:" + repo.path())
    let release = service.create(
      @release_store.access(repo, Some(actor)),
      form.get("tag").unwrap_or(""),
      form.get("target").unwrap_or("HEAD"),
      form.get("title").unwrap_or(""),
      form.get("body").unwrap_or(""),
    )
    res.send_void(
      status=303,
      headers=@web_context.redirect_headers(
        "/" + repo.path() + "/releases/" + release.id.to_string(),
      ),
    )
  })
  ctx.get("/:owner/:repo/releases/:id", async fn(req, res) {
    let repo = @web_context.repo_param(req)
    let user = @web_context.current_user_from_request(req)
    let release = service.get(
      @release_store.access(repo, user),
      @web_context.positive_resource_number(
        @web_context.required_param(req, "id", "release"),
      ),
    )
    let manager = (access_policy.manager)(req, repo)
    let csrf = if manager {
      @web_context.request_form_token(req, "release:" + release.id.to_string())
    } else {
      ""
    }
    res.send_html(
      @web_ui.layout(
        release.title,
        assets,
        Html(b => {
          b <+
            "<a href=\"/\{repo.path()}/releases\">Releases</a><div class=\"page-heading\"><h1>\{release.title}</h1><span class=\"status-badge\">\{if release.draft {"Draft"} else if release.prerelease {"Prerelease"} else {"Published"}}</span></div><p>\{release.tag} · <a href=\"/\{repo.path()}/commit/\{release.commit_sha}\"><code class=\"release-digest\">\{release.commit_sha}</code></a></p><div class=\"release-notes\">\{release.body}</div><h2>Assets</h2>"
          if release.assets.is_empty() {
            b <+ "<p>No assets uploaded.</p>"
          }
          for asset in release.assets {
            b <+
              "<article class=\"release-row\"><div><a href=\"/\{repo.path()}/releases/assets/\{asset.id.to_string()}/download\">\{asset.name}</a><p>\{asset.size.to_string()} bytes</p><code class=\"release-digest\">\{asset.digest}</code></div></article>"
          }
          if release.draft && manager {
            b <+
              "<p>Publishing fixes this version’s commit and assets. Published assets cannot be replaced.</p><form method=\"post\" action=\"/\{repo.path()}/releases/\{release.id.to_string()}/publish\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button type=\"submit\">Publish release</button></form>"
          }
        }),
        current_user=user,
        navigation=RepositoryNavigation(repo, "releases", manager),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/releases/:id/publish", async fn(req, res) {
    let repo = @web_context.repo_param(req)
    let actor = @web_context.require_current_user(req)
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "id", "release"),
    )
    ignore(@web_context.protected_form(req, "release:" + id.to_string()))
    ignore(service.publish(@release_store.access(repo, Some(actor)), id))
    res.send_void(
      status=303,
      headers=@web_context.redirect_headers(
        "/" + repo.path() + "/releases/" + id.to_string(),
      ),
    )
  })
  ctx.get("/:owner/:repo/releases/assets/:id/download", async fn(req, res) {
    let repo = @web_context.repo_param(req)
    let access = @release_store.access(
      repo,
      @web_context.current_user_from_request(req),
    )
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "id", "asset"),
    )
    @async.with_timeout(30000, () => transfers.acquire())
    defer transfers.release()
    service.download(access, id, (asset, reader, authorize) => {
      let writer = res.respond(headers={
        "Content-Type": "application/octet-stream",
        "Content-Length": asset.size.to_string(),
        "Content-Disposition": @web_context.attachment_disposition(
          asset.name,
          inline=false,
        ),
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "private, no-store",
      })
      while @async.with_timeout(30000, () => reader.read()) is Some(bytes) {
        authorize()
        @async.with_timeout(30000, () => writer.write(bytes))
      }
    })
  })
})
