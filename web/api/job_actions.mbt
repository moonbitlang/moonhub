///|
let job_actions_api_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  let results : @results.Service = ctx.require(
    @web_context.pipeline_results_key,
  )
  let origin = ctx.require(@web_context.release_origin_key)
  let transfers = @async.Semaphore(2)
  ctx.add_route(
    Patch,
    "/repos/:owner/:repo/pulls/:number",
    api_handler(req => {
      let repo = @web_context.repo_param(req)
      let token = release_token(req).unwrap_or("")
      let actor = coordinator.authenticate_job_api(
        token, repo, "pull-requests:write",
      )
      let scope = @repository.repository_scope(pool, actor, repo)
      let body = api_body(req, ["title", "body"])
      // No await separates reauthorization and the existing optimistic edit policy.
      ignore(
        coordinator.authenticate_job_api(token, repo, "pull-requests:write"),
      )
      let mr = @collaboration.require_merge_request(
        pool,
        scope,
        number(@web_context.required_param(req, "number", "pull request")),
      )
      @collaboration.edit_merge_request(
        pool,
        scope,
        actor,
        mr,
        "edit",
        field(body, "title", fallback=mr.title),
        field(body, "body", fallback=mr.description),
        expected=mr.edit_version,
      )
      let current = @collaboration.require_merge_request(pool, scope, mr.number)
      {
        "number": current.number.to_double(),
        "title": current.title,
        "body": current.description,
        "state": current.status,
        "draft": current.draft,
        "head": { "ref": current.source },
        "base": { "ref": current.target },
      }
    }),
  )
  for update in [false, true] {
    let handler = release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      let token = release_token(req).unwrap_or("")
      ignore(coordinator.authenticate_job_api(token, repo, "checks:write"))
      let fields = api_body(
        req,
        ["name", "head_sha", "status", "conclusion", "output"],
        body_limit=270000,
      )
      let result = coordinator.write_check_run(
        token,
        repo,
        fields,
        id?=if update { Some(release_id(req)) } else { None },
      )
      res.send_json(result, status=if update { 200 } else { 201 }, headers={
        "Cache-Control": "no-store",
      })
    })
    if update {
      ctx.add_route(Patch, "/repos/:owner/:repo/check-runs/:id", handler)
    } else {
      ctx.post("/repos/:owner/:repo/check-runs", handler)
    }
  }
  ctx.get(
    "/repos/:owner/:repo/commits/:sha/check-runs",
    api_handler(req => {
      let repo = @web_context.repo_param(req)
      let token = release_token(req).unwrap_or("")
      let actor = @identity.authenticate_access_token(pool, token, "read") catch {
        @domain.Unauthorized(_) =>
          coordinator.authenticate_job_api(token, repo, "checks:write")
        err => raise err
      }
      @runtime.check_runs(
        pool,
        actor,
        repo,
        @web_context.required_param(req, "sha", "commit"),
        page=page(req),
        per_page=number(req.query().get("per_page").unwrap_or("30")),
      )
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/actions/runs/:id/artifacts",
    api_handler(req => {
      let repo = @web_context.repo_param(req)
      results.list_run_artifacts(
        coordinator,
        release_token(req).unwrap_or(""),
        repo,
        release_id(req),
        release_base(origin, repo),
        name=req.query().get("name").unwrap_or(""),
        page=page(req),
        per_page=number(req.query().get("per_page").unwrap_or("30")),
      )
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/actions/artifacts/:id/zip",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      let capability = results.artifact_api_download(
        coordinator,
        release_token(req).unwrap_or(""),
        repo,
        release_id(req),
      )
      let location = release_base(origin, repo) +
        "/actions/artifacts/" +
        release_id(req).to_string() +
        "/archive?sig=" +
        capability
      ignore(
        res.respond(status=302, headers={
          "Location": location,
          "Cache-Control": "private, no-store",
          "Referrer-Policy": "no-referrer",
        }),
      )
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/actions/artifacts/:id/archive",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      let id = release_id(req)
      let capability = req.query().get("sig").unwrap_or("")
      let authorize = () => {
        ignore(
          results.artifact_api_blob(coordinator, root, repo, id, capability),
        )
      }
      authorize()
      @async.with_timeout(
        10000,
        () => transfers.acquire(),
        error=@domain.BadRequest(
          message="artifact download capacity unavailable",
        ),
      )
      defer transfers.release()
      let blob = results.artifact_api_blob(
        coordinator, root, repo, id, capability,
      )
      blob.with_reader(reader => {
        authorize()
        let writer = @async.with_timeout(30000, () => {
          res.respond(status=200, headers={
            "Content-Type": "application/zip",
            "Content-Length": blob.size.to_string(),
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
          })
        })
        @web_context.stream_artifact(() => reader.read(), writer, authorize)
      })
    }),
  )
})
