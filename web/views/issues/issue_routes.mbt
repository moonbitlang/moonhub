///|
fn issue_assignee_value(form : Map[String, String]) -> Int64 raise {
  let value = form.get("assignee").unwrap_or("0")
  if value == "0" {
    0L
  } else {
    @web_context.positive_resource_number(value)
  }
}

///|
pub let issues_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let addresses = ctx.require(@web_context.config_ssh_addresses)
  ctx.get("/:owner/:repo/issues", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    let status = req.query().get("status").unwrap_or("open")
    guard status == "open" || status == "closed" else {
      raise @domain.BadRequest(message="invalid issue status")
    }
    let page = match req.query().get("page") {
      Some(value) => @web_context.positive_resource_number(value)
      None => 1L
    }
    guard page <= 100000L else {
      raise @domain.BadRequest(message="invalid page")
    }
    let mine = req.query().get("assigned") == Some("me")
    let query = req.query().get("q").unwrap_or("").trim().to_owned()
    guard query.length() <= 200 else {
      raise @domain.BadRequest(message="search query is too long")
    }
    let issues = @collaboration.list_issues(
      pool,
      scope,
      status,
      page,
      mine,
      actor.id,
      query,
    )
    let clone = @repository.effective_ssh_endpoint(pool, addresses).map(endpoint => {
      endpoint.clone_url(scope.repo)
    })
    res.send_html(
      render_issue_list(
        assets,
        actor,
        scope,
        issues,
        status,
        page,
        mine,
        query,
        @repository.can_access_repository(
          pool,
          actor,
          scope.repo,
          @repository.Write,
        ),
        clone,
        manager=@identity.can_manage_team(pool, actor, scope.team_id),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/:owner/:repo/issues/new", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
    res.send_html(
      render_issue_form(
        assets,
        actor,
        scope,
        None,
        manager=@identity.can_manage_team(pool, actor, scope.team_id),
        @collaboration.issue_assignees(pool, scope),
        @web_context.request_form_token(req, "issues"),
        Map([]),
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/issues", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
    let form = @web_context.protected_form(req, "issues")
    let number = @collaboration.create_issue(
      pool,
      scope,
      actor,
      form.get("title").unwrap_or(""),
      form.get("description").unwrap_or(""),
      issue_assignee_value(form),
    ) catch {
      @domain.BadRequest(message~) => {
        res.send_html(
          render_issue_form(
            assets,
            actor,
            scope,
            None,
            @collaboration.issue_assignees(pool, scope),
            @web_context.request_form_token(req, "issues"),
            form,
            Some(message),
            manager=@identity.can_manage_team(pool, actor, scope.team_id),
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
        location="\{@web_ui.repo_link(scope.repo)}/issues/\{number}",
      ),
    )
  })
  ctx.get("/:owner/:repo/issues/:number", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    let issue = @collaboration.require_issue(
      pool,
      scope,
      @web_context.positive_resource_number(
        @web_context.required_param(req, "number", "issue"),
      ),
    )
    let page = match req.query().get("page") {
      Some(value) => @web_context.positive_resource_number(value)
      None => 1L
    }
    guard page <= 100000L else {
      raise @domain.BadRequest(message="invalid page")
    }
    let activity = @collaboration.list_issue_activity(pool, issue, page)
    let related = @collaboration.issue_merge_requests(pool, scope, issue)
    let clone = @repository.effective_ssh_endpoint(pool, addresses).map(endpoint => {
      endpoint.clone_url(scope.repo)
    })
    res.send_html(
      render_issue_detail(
        assets,
        actor,
        scope,
        issue,
        activity,
        page,
        related,
        @repository.can_access_repository(
          pool,
          actor,
          scope.repo,
          @repository.Write,
        ),
        @identity.can_manage_team(pool, actor, scope.team_id),
        @web_context.request_form_token(req, "issues"),
        clone,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/:owner/:repo/issues/:number/edit", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
    let issue = @collaboration.require_issue(
      pool,
      scope,
      @web_context.positive_resource_number(
        @web_context.required_param(req, "number", "issue"),
      ),
    )
    guard issue.author_id == actor.id ||
      @identity.can_manage_team(pool, actor, scope.team_id) else {
      raise @domain.Forbidden(
        message="only the author or a team administrator may edit this issue",
      )
    }
    res.send_html(
      render_issue_form(
        assets,
        actor,
        scope,
        Some(issue),
        @collaboration.issue_assignees(pool, scope),
        @web_context.request_form_token(req, "issues"),
        Map([]),
        None,
        manager=@identity.can_manage_team(pool, actor, scope.team_id),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/issues/:number/:action", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    let form = @web_context.protected_form(req, "issues")
    let issue = @collaboration.require_issue(
      pool,
      scope,
      @web_context.positive_resource_number(
        @web_context.required_param(req, "number", "issue"),
      ),
    )
    let action = @web_context.required_param(req, "action", "action")
    let expected = if action == "comment" {
      issue.edit_version
    } else {
      @web_context.positive_resource_number(
        form.get("edit_version").unwrap_or(""),
      )
    }
    @collaboration.mutate_issue(
      pool,
      scope,
      actor,
      issue,
      expected,
      action,
      form.get("title").unwrap_or(""),
      form.get("description").unwrap_or(""),
      issue_assignee_value(form),
      form.get("body").unwrap_or(""),
    ) catch {
      @domain.BadRequest(message~) if action == "edit" => {
        res.send_html(
          render_issue_form(
            assets,
            actor,
            scope,
            Some(issue),
            @collaboration.issue_assignees(pool, scope),
            @web_context.request_form_token(req, "issues"),
            form,
            Some(message),
            manager=@identity.can_manage_team(pool, actor, scope.team_id),
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
        location="\{@web_ui.repo_link(scope.repo)}/issues/\{issue.number}",
      ),
    )
  })
})
