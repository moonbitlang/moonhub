///|
pub let merge_requests_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  let addresses = ctx.require(@web_context.config_ssh_addresses)
  ctx.get("/:owner/:repo/merge-requests", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    let status = req.query().get("status").unwrap_or("open")
    guard status == "open" || status == "closed" || status == "merged" else {
      raise @domain.BadRequest(message="invalid merge request status")
    }
    let page = match req.query().get("page") {
      Some(value) => @web_context.positive_resource_number(value)
      None => 1L
    }
    guard page <= 100000L else {
      raise @domain.BadRequest(message="invalid page")
    }
    let rows = @collaboration.list_merge_requests(pool, scope, status, page)
    let clone = @repository.effective_ssh_endpoint(pool, addresses).map(endpoint => {
      endpoint.clone_url(scope.repo)
    })
    res.send_html(
      render_merge_list(
        assets,
        actor,
        scope,
        rows,
        status,
        page,
        @repository.can_access_repository(
          pool,
          actor,
          scope.repo,
          @repository.Write,
        ),
        @identity.can_manage_team(pool, actor, scope.team_id),
        clone,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/:owner/:repo/merge-requests/new", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
    let git_dir = @repository.resolve_repository_dir(root, scope.repo)
    let branches = @domain.split_lines(
      @gitops.merge_git(git_dir, [
        "for-each-ref", "--format=%(refname:strip=2)", "--count=1000", "refs/heads/",
      ]),
    )
    res.send_html(
      render_merge_new(
        assets,
        actor,
        scope,
        branches,
        @gitops.default_ref(git_dir),
        @web_context.request_form_token(req, "merge-requests"),
        { "issue": req.query().get("issue").unwrap_or("") },
        None,
        manager=@identity.can_manage_team(pool, actor, scope.team_id),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/merge-requests", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let form = @web_context.protected_form(req, "merge-requests")
    let repo = @web_context.repo_param(req)
    let created = @repository.with_repository_write(pool, root, actor, repo, (
      scope,
      git_dir,
    ) => {
      let issue = form.get("issue").unwrap_or("")
      @collaboration.create_merge_request(
        pool,
        scope,
        git_dir,
        actor,
        form.get("title").unwrap_or(""),
        form.get("description").unwrap_or(""),
        form.get("source").unwrap_or(""),
        form.get("target").unwrap_or(""),
        form.get("draft") == Some("on"),
        issue=if issue.is_empty() {
          0L
        } else {
          @web_context.positive_resource_number(issue)
        },
      )
    }) catch {
      @domain.BadRequest(message~) | @gitops.Failure(message~) => {
        let scope = @repository.repository_scope(pool, actor, repo)
        let git_dir = @repository.resolve_repository_dir(root, repo)
        let branches = @domain.split_lines(
          @gitops.merge_git(git_dir, [
            "for-each-ref", "--format=%(refname:strip=2)", "--count=1000", "refs/heads/",
          ]),
        )
        res.send_html(
          render_merge_new(
            assets,
            actor,
            scope,
            branches,
            @gitops.default_ref(git_dir),
            @web_context.request_form_token(req, "merge-requests"),
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
        location="\{@web_ui.repo_link(repo)}/merge-requests/\{created.number}",
      ),
    )
  })
  ctx.get("/:owner/:repo/merge-requests/:number", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    let git_dir = @repository.resolve_repository_dir(root, scope.repo)
    let number = @web_context.positive_resource_number(
      @web_context.required_param(req, "number", "merge request"),
    )
    let mut mr = @collaboration.require_merge_request(pool, scope, number)
    let mut stale = ""
    if mr.status == "open" {
      try {
        let lock = @gitops.repository_write_lock(git_dir)
        defer lock.close()
        mr = @collaboration.refresh_merge_request(
          pool,
          scope,
          git_dir,
          @collaboration.require_merge_request(pool, scope, number),
        )
      } catch {
        @domain.BadRequest(message~) | @gitops.Failure(message~) =>
          stale = message
        err => raise err
      }
    }
    let selected = match req.query().get("version") {
      Some(value) => @web_context.positive_resource_number(value)
      None => mr.version
    }
    let revision = if selected > 0L {
      Some(@collaboration.merge_revision(pool, mr, version=selected))
    } else {
      None
    }
    let tab = req.query().get("tab").unwrap_or("discussion")
    guard tab == "discussion" || tab == "commits" || tab == "changes" else {
      raise @domain.BadRequest(message="invalid merge request tab")
    }
    let mut patch = ""
    let mut diff_error = ""
    let commits : Array[@gitops.CommitInfo] = []
    if revision is Some(revision) {
      if tab == "changes" {
        try {
          patch = @gitops.merge_git(git_dir, [
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--find-renames",
            revision.base_sha,
            revision.source_sha,
            "--",
          ])
        } catch {
          @domain.BadRequest(message~) | @gitops.Failure(message~) =>
            diff_error = message
          err => raise err
        }
      }
      if tab == "commits" {
        let output = @gitops.merge_git(git_dir, [
          "log",
          "--date=short",
          "--pretty=format:%H%x1f%s%x1f%an%x1f%ad",
          "-n",
          "100",
          "\{revision.target_sha}..\{revision.source_sha}",
          "--",
        ])
        for line in @domain.split_lines(output) {
          if @gitops.parse_commit_line(line) is Some(commit) {
            commits.push(commit)
          }
        }
      }
    }
    let current = if mr.version > 0L {
      Some(@collaboration.merge_revision(pool, mr))
    } else {
      None
    }
    let blocker = if !stale.is_empty() {
      stale
    } else {
      match current {
        Some(revision) =>
          @collaboration.merge_blocker(pool, scope, mr, revision)
        None => "Comparison is not available; refresh to retry."
      }
    }
    let activity_page = match req.query().get("page") {
      Some(value) => @web_context.positive_resource_number(value)
      None => 1L
    }
    guard activity_page <= 100000L else {
      raise @domain.BadRequest(message="invalid page")
    }
    let activities = @collaboration.list_merge_activity(pool, mr, activity_page)
    let (approved, _) = @collaboration.merge_review_counts(pool, scope, mr)
    let clone = @repository.effective_ssh_endpoint(pool, addresses).map(endpoint => {
      endpoint.clone_url(scope.repo)
    })
    res.send_html(
      render_merge_detail(
        assets,
        actor,
        scope,
        mr,
        revision,
        tab,
        activities,
        activity_page,
        commits,
        patch,
        diff_error,
        blocker,
        approved,
        @collaboration.required_merge_approvals(pool, scope, mr.target),
        @repository.can_access_repository(
          pool,
          actor,
          scope.repo,
          @repository.Write,
        ),
        @identity.can_manage_team(pool, actor, scope.team_id),
        @web_context.request_form_token(req, "merge-requests"),
        clone,
      ),
      headers=@web_context.private_page_headers(
        refresh=mr.job_status == "pending" || mr.job_status == "running",
      ),
    )
  })
  ctx.post("/:owner/:repo/merge-requests/:number/:action", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let number = @web_context.positive_resource_number(
      @web_context.required_param(req, "number", "merge request"),
    )
    let action = @web_context.required_param(req, "action", "action")
    let form = @web_context.protected_form(req, "merge-requests")
    @repository.with_repository_write(pool, root, actor, repo, (scope, git_dir) => {
      let mr = @collaboration.require_merge_request(pool, scope, number)
      if action == "review" || action == "merge" {
        let mr = if action == "review" &&
          form.get("decision") == Some("comment") {
          mr
        } else {
          @collaboration.refresh_merge_request(pool, scope, git_dir, mr)
        }
        let version = @web_context.positive_resource_number(
          form.get("version").unwrap_or(""),
        )
        if action == "merge" {
          @collaboration.enqueue_merge(pool, scope, actor, mr, version)
        } else {
          @collaboration.submit_merge_review(
            pool,
            actor,
            mr,
            version,
            form.get("decision").unwrap_or("comment"),
            form.get("body").unwrap_or(""),
          )
        }
      } else {
        @collaboration.edit_merge_request(
          pool,
          scope,
          actor,
          mr,
          action,
          form.get("title").unwrap_or(""),
          form.get("description").unwrap_or(""),
          expected=@web_context.positive_resource_number(
            form.get("edit_version").unwrap_or(""),
          ),
        )
      }
    })
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location="\{@web_ui.repo_link(repo)}/merge-requests/\{number}",
      ),
    )
  })
  ctx.get("/:owner/:repo/settings/branches", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    guard @identity.can_manage_team(pool, actor, scope.team_id) else {
      raise @domain.Forbidden(message="team owner or admin required")
    }
    let rules = @collaboration.branch_rules(pool, scope)
    res.send_html(
      render_branch_rules(
        assets,
        actor,
        scope,
        rules,
        @web_context.request_form_token(req, "branch-rules"),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/settings/branches", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let form = @web_context.protected_form(req, "branch-rules")
    let approvals = match form.get("approvals").unwrap_or("1") {
      "0" => 0L
      "1" => 1L
      _ => raise @domain.BadRequest(message="invalid approval requirement")
    }
    @repository.with_repository_write(pool, root, actor, repo, (scope, git_dir) => {
      @collaboration.save_branch_rule(
        pool,
        scope,
        git_dir,
        actor,
        form.get("branch").unwrap_or(""),
        form.get("action") != Some("remove"),
        approvals,
      )
    })
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location="\{@web_ui.repo_link(repo)}/settings/branches",
      ),
    )
  })
})
