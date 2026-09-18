///|
fn pipeline_number(req : @moonback.Request) -> Int64 raise {
  @web_context.positive_resource_number(
    @web_context.required_param(req, "number", "pipeline run"),
  )
}

///|
fn pipeline_scope(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  req : @moonback.Request,
) -> @repository.RepositoryScope raise {
  @repository.repository_scope(pool, actor, @web_context.repo_param(req))
}

///|
fn require_pipeline_manager(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
) -> Unit raise {
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
  guard @identity.can_manage_team(pool, actor, scope.team_id) else {
    raise @domain.Forbidden(message="repository owner or admin required")
  }
}

///|
pub let pipeline_pages_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  ctx.get("/:owner/:repo/pipelines", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    let manager = @identity.can_manage_team(pool, actor, scope.team_id)
    res.send_html(
      render_pipeline_list(
        assets,
        actor,
        scope,
        @pipeline.list_runs(pool, actor, scope.repo),
        manager,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/:owner/:repo/pipelines/new", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    require_pipeline_manager(pool, actor, scope)
    res.send_html(
      render_pipeline_form(
        assets,
        actor,
        scope,
        @web_context.request_form_token(req, "pipelines:create"),
        req.query().get("branch").unwrap_or("pipeline"),
        req.query().get("workflow").unwrap_or(".github/workflows/build.yml"),
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/pipelines", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    require_pipeline_manager(pool, actor, scope)
    let form = @web_context.protected_form(req, "pipelines:create")
    let branch = form.get("branch").unwrap_or("").trim().to_owned()
    let workflow = form.get("workflow").unwrap_or("").trim().to_owned()
    let run = @pipeline.create_run(
      pool,
      root,
      actor,
      scope.repo,
      branch,
      workflow,
    ) catch {
      @domain.BadRequest(message~) => {
        res.send_html(
          render_pipeline_form(
            assets,
            actor,
            scope,
            @web_context.request_form_token(req, "pipelines:create"),
            branch,
            workflow,
            Some(message),
          ),
          status=400,
          headers=@web_context.private_page_headers(),
        )
        return
      }
      err => raise err
    }
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location=@web_ui.repo_link(scope.repo) +
          "/pipelines/" +
          run.number.to_string(),
      ),
    )
  })
  ctx.get("/:owner/:repo/pipelines/:number", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    let number = pipeline_number(req)
    let run = @pipeline.get_run(pool, actor, scope.repo, number)
    let jobs = @pipeline.list_jobs(pool, actor, scope.repo, number)
    let pages : Array[PipelineJobPage] = []
    for job in jobs {
      match job.attempt_id {
        None => pages.push({ job, steps: [], logs: [], })
        Some(attempt_id) =>
          pages.push({
            job,
            steps: coordinator.read_steps(actor, scope.repo, number, attempt_id),
            logs: coordinator.read_logs(actor, scope.repo, number, attempt_id),
          })
      }
    }
    let manager = @identity.can_manage_team(pool, actor, scope.team_id)
    res.send_html(
      render_pipeline_detail(
        assets,
        actor,
        scope,
        run,
        pages,
        manager,
        @web_context.request_form_token(req, "pipelines:" + run.id.to_string()),
      ),
      headers=@web_context.private_page_headers(
        refresh=run.state is @pipeline.Queued || run.state is @pipeline.Running,
      ),
    )
  })
  ctx.post("/:owner/:repo/pipelines/:number/cancel", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    let number = pipeline_number(req)
    let run = @pipeline.get_run(pool, actor, scope.repo, number)
    ignore(@web_context.protected_form(req, "pipelines:" + run.id.to_string()))
    coordinator.cancel_run(actor, scope.repo, number)
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location=@web_ui.repo_link(scope.repo) +
          "/pipelines/" +
          number.to_string(),
      ),
    )
  })
  ctx.post("/:owner/:repo/pipelines/:number/rerun", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    let number = pipeline_number(req)
    let run = @pipeline.get_run(pool, actor, scope.repo, number)
    ignore(@web_context.protected_form(req, "pipelines:" + run.id.to_string()))
    let rerun = @pipeline.rerun_run(pool, root, actor, scope.repo, number)
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location=@web_ui.repo_link(scope.repo) +
          "/pipelines/" +
          rerun.number.to_string(),
      ),
    )
  })
})
