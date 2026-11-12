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
fn parse_provider_access(
  scope : String,
  repositories : String,
) -> (@pipeline.ProviderScope, Array[@domain.RepoId]) raise {
  let scope = @pipeline.ProviderScope::parse(scope)
  let repos : Array[@domain.RepoId] = []
  if scope is @pipeline.SelectedRepositories {
    for path in repositories.split(",") {
      let path = path.trim()
      if !path.is_empty() {
        repos.push(@domain.parse_transport_repo(path.to_owned()))
      }
    }
  }
  (scope, repos)
}

///|
pub let pipeline_pages_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  ctx.use_(pipeline_updates_module)
  ctx.use_(provider_config_module)
  ctx.get("/:owner/:repo/actions/runs/:run/artifacts/:artifact", async fn(
    req,
    res,
  ) {
    let actor = @web_context.require_current_user(req)
    let blob = coordinator.user_artifact(
      root,
      actor,
      @web_context.repo_param(req),
      @web_context.positive_resource_number(
        @web_context.required_param(req, "run", "run"),
      ),
      @web_context.positive_resource_number(
        @web_context.required_param(req, "artifact", "artifact"),
      ),
    )
    blob.with_reader(reader => {
      let writer = @async.with_timeout(30000, () => {
        res.respond(headers={
          "Content-Type": "application/zip",
          "Content-Length": blob.size.to_string(),
          "Content-Disposition": "attachment; filename=artifact.zip",
          "Cache-Control": "private, no-store",
          "X-Content-Type-Options": "nosniff",
        })
      })
      stream_artifact(() => reader.read(), writer, () => {
        ignore(
          coordinator.user_artifact(
            root,
            actor,
            @web_context.repo_param(req),
            @web_context.positive_resource_number(
              @web_context.required_param(req, "run", "run"),
            ),
            blob.id,
          ),
        )
      })
    })
  })
  ctx.get("/-/admin/pipelines/providers", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    res.send_html(
      render_provider_admin(
        assets,
        actor,
        coordinator.list_providers(actor),
        @web_context.request_form_token(req, "pipeline-providers"),
        None,
        None,
        labels_saved=req.query().get("labels_saved") == Some("1"),
        scope_saved=req.query().get("scope_saved") == Some("1"),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/-/admin/pipelines/providers", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    let form = @web_context.protected_form(req, "pipeline-providers")
    let name = form.get("name").unwrap_or("").trim().to_owned()
    let labels = form
      .get("labels")
      .unwrap_or("")
      .split(",")
      .filter(label => !label.trim().is_empty())
      .map(label => label.trim().to_owned())
      .collect()
    let token = @identity.random_hex(32)
    try {
      let (scope, repositories) = parse_provider_access(
        form.get("scope").unwrap_or("selected"),
        form.get("repositories").unwrap_or(""),
      )
      ignore(
        coordinator.create_provider(
          actor,
          name,
          token,
          labels,
          repositories,
          scope~,
        ),
      )
    } catch {
      @domain.BadRequest(message~)
      | @domain.NotFound(message~)
      | @pipeline.Conflict(message) => {
        res.send_html(
          render_provider_admin(
            assets,
            actor,
            coordinator.list_providers(actor),
            @web_context.request_form_token(req, "pipeline-providers"),
            None,
            Some(message),
            registration={
              "name": name,
              "labels": form.get("labels").unwrap_or(""),
              "scope": form.get("scope").unwrap_or("selected"),
              "repositories": form.get("repositories").unwrap_or(""),
            },
          ),
          status=400,
          headers=@web_context.private_page_headers(),
        )
        return
      }
      err => raise err
    }
    res.send_html(
      render_provider_admin(
        assets,
        actor,
        coordinator.list_providers(actor),
        @web_context.request_form_token(req, "pipeline-providers"),
        Some(token),
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/-/admin/pipelines/providers/:id/labels", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "id", "provider"),
    )
    let provider = coordinator
      .list_providers(actor)
      .iter()
      .find_first(provider => provider.id == id && !provider.revoked)
    guard provider is Some(provider) else {
      raise @domain.NotFound(message="provider not found")
    }
    res.send_html(
      render_provider_labels(
        assets,
        actor,
        provider,
        @web_context.request_form_token(req, "pipeline-providers"),
        provider.labels.join(","),
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/-/admin/pipelines/providers/:id/access", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "id", "provider"),
    )
    let provider = coordinator
      .list_providers(actor)
      .iter()
      .find_first(p => p.id == id && !p.revoked)
    guard provider is Some(provider) else {
      raise @domain.NotFound(message="provider not found")
    }
    res.send_html(
      render_provider_access(
        assets,
        actor,
        provider,
        @web_context.request_form_token(req, "pipeline-providers"),
        provider.scope.value(),
        provider.repositories.join(","),
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/-/admin/pipelines/providers/:id/access", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    let form = @web_context.protected_form(req, "pipeline-providers")
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "id", "provider"),
    )
    let provider = coordinator
      .list_providers(actor)
      .iter()
      .find_first(p => p.id == id && !p.revoked)
    guard provider is Some(provider) else {
      raise @domain.NotFound(message="provider not found")
    }
    let scope_value = form.get("scope").unwrap_or("")
    let repositories_value = form.get("repositories").unwrap_or("")
    try {
      let (scope, repositories) = parse_provider_access(
        scope_value, repositories_value,
      )
      coordinator.set_provider_scope(actor, id, scope, repositories)
    } catch {
      @domain.BadRequest(message~) | @domain.NotFound(message~) => {
        res.send_html(
          render_provider_access(
            assets,
            actor,
            provider,
            @web_context.request_form_token(req, "pipeline-providers"),
            scope_value,
            repositories_value,
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
        location="/-/admin/pipelines/providers?scope_saved=1",
      ),
    )
  })
  ctx.post("/-/admin/pipelines/providers/:id/labels", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    let form = @web_context.protected_form(req, "pipeline-providers")
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "id", "provider"),
    )
    let provider = coordinator
      .list_providers(actor)
      .iter()
      .find_first(provider => provider.id == id && !provider.revoked)
    guard provider is Some(provider) else {
      raise @domain.NotFound(message="provider not found")
    }
    let value = form.get("labels").unwrap_or("")
    let labels = value
      .split(",")
      .map(label => label.trim().to_owned())
      .collect()
    coordinator.set_provider_labels(actor, id, labels) catch {
      @domain.BadRequest(message~) => {
        res.send_html(
          render_provider_labels(
            assets,
            actor,
            provider,
            @web_context.request_form_token(req, "pipeline-providers"),
            value,
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
        location="/-/admin/pipelines/providers?labels_saved=1",
      ),
    )
  })
  ctx.post("/-/admin/pipelines/providers/:id/pause", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    let form = @web_context.protected_form(req, "pipeline-providers")
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "id", "provider"),
    )
    coordinator.set_provider_paused(actor, id, form.get("paused") == Some("1"))
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location="/-/admin/pipelines/providers",
      ),
    )
  })
  ctx.post("/-/admin/pipelines/providers/:id/revoke", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    guard actor.is_site_admin else {
      raise @domain.Forbidden(message="site administrator required")
    }
    ignore(@web_context.protected_form(req, "pipeline-providers"))
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "id", "provider"),
    )
    coordinator.revoke_provider(actor, id)
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location="/-/admin/pipelines/providers",
      ),
    )
  })
  ctx.get("/:owner/:repo/pipelines", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    let manager = @identity.can_manage_team(pool, actor, scope.team_id)
    let tab = req.query().get("tab").unwrap_or("runs")
    guard ["runs", "events", "settings"].contains(tab) else {
      raise @domain.BadRequest(message="invalid pipeline tab")
    }
    if tab == "settings" {
      require_pipeline_manager(pool, actor, scope)
    }
    let page = @web_context.positive_resource_number(
      req.query().get("page").unwrap_or("1"),
    )
    let status = req.query().get("status").unwrap_or("")
    let branch = req.query().get("branch").unwrap_or("")
    let workflow = req.query().get("workflow").unwrap_or("")
    res.send_html(
      render_pipeline_list(
        assets,
        actor,
        scope,
        if tab == "runs" {
          @pipeline.list_runs(
            pool,
            actor,
            scope.repo,
            page~,
            status~,
            branch~,
            workflow~,
          )
        } else {
          []
        },
        manager,
        if tab == "settings" {
          @repository.pipeline_push_enabled(pool, actor, scope.repo)
        } else {
          false
        },
        @web_context.request_form_token(req, "pipelines:settings"),
        if tab == "events" {
          @pipeline.list_trigger_events(pool, actor, scope.repo)
        } else {
          []
        },
        tab,
        page,
        status,
        branch,
        workflow,
        req.query().get("saved") == Some("1"),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/pipelines/settings", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    require_pipeline_manager(pool, actor, scope)
    let form = @web_context.protected_form(req, "pipelines:settings")
    @repository.set_pipeline_push_enabled(
      pool,
      root,
      actor,
      scope.repo,
      form.get("push_enabled") == Some("1"),
    )
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location=@web_ui.repo_link(scope.repo) +
          "/pipelines?tab=settings&saved=1",
      ),
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
        @pipeline.dispatch_choices(
          pool,
          root,
          actor,
          scope.repo,
          req.query().get("branch").unwrap_or(""),
        ),
        req.query().get("workflow").unwrap_or(""),
        Map([]),
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/pipelines", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    require_pipeline_manager(pool, actor, scope)
    // Percent encoding may triple the bounded dispatch input JSON size.
    let form = @web_context.protected_form(
      req,
      "pipelines:create",
      limit=212992,
    )
    let branch = form.get("branch").unwrap_or("").trim().to_owned()
    let workflow = form.get("workflow").unwrap_or("").trim().to_owned()
    let inputs : Map[String, Json] = Map([])
    let values : Map[String, String] = Map([])
    values["__job"] = form.get("job").unwrap_or("")
    for key, value in form {
      if key.strip_prefix("input:") is Some(name) {
        inputs[name.to_owned()] = Json(value)
        values[name.to_owned()] = value
      }
    }
    let run = @pipeline.create_run(
      pool,
      root,
      actor,
      scope.repo,
      branch,
      workflow,
      inputs~,
      jobs=if form.get("job").unwrap_or("").is_empty() {
        []
      } else {
        [form.get("job").unwrap()]
      },
    ) catch {
      @domain.BadRequest(message~) => {
        res.send_html(
          render_pipeline_form(
            assets,
            actor,
            scope,
            @web_context.request_form_token(req, "pipelines:create"),
            @pipeline.dispatch_choices(pool, root, actor, scope.repo, branch) catch {
              @domain.BadRequest(_) => {
                let current = @pipeline.dispatch_choices(
                  pool,
                  root,
                  actor,
                  scope.repo,
                  "",
                )
                { ..current, branch, commit: "", workflows: [], }
              }
              err => raise err
            },
            workflow,
            values,
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
    let reasons = coordinator.queue_reasons(actor, scope.repo, number)
    let pages : Array[PipelineJobPage] = []
    for job in jobs {
      match job.attempt_id {
        None =>
          pages.push({
            job,
            steps: [],
            logs: None,
            reason: reasons.get(job.job_key),
          })
        Some(attempt_id) =>
          pages.push({
            job,
            steps: coordinator.read_steps(actor, scope.repo, number, attempt_id),
            logs: Some(
              coordinator.read_log_page(actor, scope.repo, number, attempt_id),
            ),
            reason: reasons.get(job.job_key),
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
        @pipeline.merge_check_context(pool, actor, scope.repo, number),
      ),
      headers=@web_context.private_page_headers(),
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
