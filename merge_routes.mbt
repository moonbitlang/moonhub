///|
fn merge_number(value : String) -> Int64 raise {
  let number = @string.parse_int64(value) catch {
    _ => raise BadRequest(message="invalid merge request number")
  }
  guard number > 0L else {
    raise BadRequest(message="invalid merge request number")
  }
  number
}

///|
fn merge_requests_module(assets : Map[String, String]) -> @moonback.Module {
  Module(ctx => {
    let pool = db_pool(ctx)
    let root = repo_root(ctx)
    let addresses = ctx
      .config()
      .get_custom(config_ssh_addresses)
      .unwrap_or(no_ssh_address_config)
    ctx.get("/:owner/:repo/merge-requests", async fn(req, res) {
      let actor = require_current_user(req)
      let scope = repository_scope(pool, actor, req.repo_param())
      let status = req.query().get("status").unwrap_or("open")
      guard status == "open" || status == "closed" || status == "merged" else {
        raise BadRequest(message="invalid merge request status")
      }
      let page = match req.query().get("page") {
        Some(value) => merge_number(value)
        None => 1L
      }
      guard page <= 100000L else { raise BadRequest(message="invalid page") }
      let rows = pool.with_client(client => {
        client
        .query_all(
          "\{merge_request_select} WHERE m.repository_id = ? AND m.status = ? ORDER BY m.number DESC LIMIT 51 OFFSET ?",
          params=[scope.id, status, (page - 1L) * 50L],
        )
        .map(MergeRequest::from_row)
      })
      let clone = effective_ssh_endpoint(pool, addresses).map(endpoint => {
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
          can_access_repository(pool, actor, scope.repo, Write),
          can_manage_team(pool, actor, scope.team_id),
          clone,
        ),
        headers=private_page_headers(),
      )
    })
    ctx.get("/:owner/:repo/merge-requests/new", async fn(req, res) {
      let actor = require_current_user(req)
      let scope = repository_scope(pool, actor, req.repo_param())
      authorize_repository(pool, actor, scope.repo, Write)
      let git_dir = resolve_repository_dir(root, scope.repo)
      let branches = split_lines(
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
          default_ref(git_dir),
          request_form_token(req, "merge-requests"),
          { "issue": req.query().get("issue").unwrap_or("") },
          None,
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/:owner/:repo/merge-requests", async fn(req, res) {
      let actor = require_current_user(req)
      let form = protected_form(req, "merge-requests")
      let repo = req.repo_param()
      let created = with_repository_write(pool, root, actor, repo, (
        scope,
        git_dir,
      ) => {
        let issue = form.get("issue").unwrap_or("")
        create_merge_request(
          pool,
          scope,
          git_dir,
          actor,
          form.get("title").unwrap_or(""),
          form.get("description").unwrap_or(""),
          form.get("source").unwrap_or(""),
          form.get("target").unwrap_or(""),
          form.get("draft") == Some("on"),
          issue=if issue.is_empty() { 0L } else { merge_number(issue) },
        )
      }) catch {
        BadRequest(message~) | @gitops.Failure(message~) => {
          let scope = repository_scope(pool, actor, repo)
          let git_dir = resolve_repository_dir(root, repo)
          let branches = split_lines(
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
              default_ref(git_dir),
              request_form_token(req, "merge-requests"),
              form,
              Some(message),
            ),
            status=400,
            headers=private_page_headers(),
          )
          return
        }
        err => raise err
      }
      res.send_void(
        status=303,
        headers=private_page_headers(
          location="\{repo_link(repo)}/merge-requests/\{created.number}",
        ),
      )
    })
    ctx.get("/:owner/:repo/merge-requests/:number", async fn(req, res) {
      let actor = require_current_user(req)
      let scope = repository_scope(pool, actor, req.repo_param())
      let git_dir = resolve_repository_dir(root, scope.repo)
      let number = merge_number(req.required_param("number", "merge request"))
      let mut mr = require_merge_request(pool, scope, number)
      let mut stale = ""
      if mr.status == "open" {
        try {
          let lock = @gitops.repository_write_lock(git_dir)
          defer lock.close()
          mr = refresh_merge_request(
            pool,
            scope,
            git_dir,
            require_merge_request(pool, scope, number),
          )
        } catch {
          BadRequest(message~) | @gitops.Failure(message~) => stale = message
          err => raise err
        }
      }
      let selected = match req.query().get("version") {
        Some(value) => merge_number(value)
        None => mr.version
      }
      let revision = if selected > 0L {
        Some(merge_revision(pool, mr, version=selected))
      } else {
        None
      }
      let tab = req.query().get("tab").unwrap_or("discussion")
      guard tab == "discussion" || tab == "commits" || tab == "changes" else {
        raise BadRequest(message="invalid merge request tab")
      }
      let mut patch = ""
      let mut diff_error = ""
      let commits : Array[CommitInfo] = []
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
            BadRequest(message~) | @gitops.Failure(message~) =>
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
          for line in split_lines(output) {
            if parse_commit_line(line) is Some(commit) {
              commits.push(commit)
            }
          }
        }
      }
      let current = if mr.version > 0L {
        Some(merge_revision(pool, mr))
      } else {
        None
      }
      let blocker = if !stale.is_empty() {
        stale
      } else {
        match current {
          Some(revision) => merge_blocker(pool, scope, mr, revision)
          None => "Comparison is not available; refresh to retry."
        }
      }
      let activity_page = match req.query().get("page") {
        Some(value) => merge_number(value)
        None => 1L
      }
      guard activity_page <= 100000L else {
        raise BadRequest(message="invalid page")
      }
      let activities = pool.with_client(client => {
        client.query_all(
          "SELECT a.*, COALESCE(u.display_name, 'Moonhub') AS actor FROM merge_activity AS a LEFT JOIN \"user\" AS u ON u.id = a.actor_id WHERE a.merge_request_id = ? ORDER BY a.id DESC LIMIT 51 OFFSET ?",
          params=[mr.id, (activity_page - 1L) * 50L],
        )
      })
      let (approved, _) = merge_review_counts(pool, scope, mr)
      let clone = effective_ssh_endpoint(pool, addresses).map(endpoint => {
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
          required_merge_approvals(pool, scope, mr.target),
          can_access_repository(pool, actor, scope.repo, Write),
          can_manage_team(pool, actor, scope.team_id),
          request_form_token(req, "merge-requests"),
          clone,
        ),
        headers=private_page_headers(
          refresh=mr.job_status == "pending" || mr.job_status == "running",
        ),
      )
    })
    ctx.post("/:owner/:repo/merge-requests/:number/:action", async fn(
      req,
      res,
    ) {
      let actor = require_current_user(req)
      let repo = req.repo_param()
      let number = merge_number(req.required_param("number", "merge request"))
      let action = req.required_param("action", "action")
      let form = protected_form(req, "merge-requests")
      with_repository_write(pool, root, actor, repo, (scope, git_dir) => {
        let mr = require_merge_request(pool, scope, number)
        if action == "review" || action == "merge" {
          let mr = if action == "review" &&
            form.get("decision") == Some("comment") {
            mr
          } else {
            refresh_merge_request(pool, scope, git_dir, mr)
          }
          let version = merge_number(form.get("version").unwrap_or(""))
          if action == "merge" {
            enqueue_merge(pool, scope, actor, mr, version)
          } else {
            submit_merge_review(
              pool,
              actor,
              mr,
              version,
              form.get("decision").unwrap_or("comment"),
              form.get("body").unwrap_or(""),
            )
          }
        } else {
          edit_merge_request(
            pool,
            scope,
            actor,
            mr,
            action,
            form.get("title").unwrap_or(""),
            form.get("description").unwrap_or(""),
            expected=merge_number(form.get("edit_version").unwrap_or("")),
          )
        }
      })
      res.send_void(
        status=303,
        headers=private_page_headers(
          location="\{repo_link(repo)}/merge-requests/\{number}",
        ),
      )
    })
    ctx.get("/:owner/:repo/settings/branches", async fn(req, res) {
      let actor = require_current_user(req)
      let scope = repository_scope(pool, actor, req.repo_param())
      guard can_manage_team(pool, actor, scope.team_id) else {
        raise Forbidden(message="team owner or admin required")
      }
      let rules = pool.with_client(client => {
        client.query_all(
          "SELECT branch, required_approvals FROM branch_rule WHERE repository_id = ? ORDER BY branch",
          params=[scope.id],
        )
      })
      res.send_html(
        render_branch_rules(
          assets,
          actor,
          scope,
          rules,
          request_form_token(req, "branch-rules"),
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/:owner/:repo/settings/branches", async fn(req, res) {
      let actor = require_current_user(req)
      let repo = req.repo_param()
      let form = protected_form(req, "branch-rules")
      let approvals = match form.get("approvals").unwrap_or("1") {
        "0" => 0L
        "1" => 1L
        _ => raise BadRequest(message="invalid approval requirement")
      }
      with_repository_write(pool, root, actor, repo, (scope, git_dir) => {
        save_branch_rule(
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
        headers=private_page_headers(
          location="\{repo_link(repo)}/settings/branches",
        ),
      )
    })
  })
}
