///|
pub let merge_requests_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  let addresses = ctx.require(@web_context.config_ssh_addresses)
  let diff_executor = ctx.require(@web_context.diff_executor_key)
  let diff_enabled = ctx.require(@web_context.diff_enabled_key)
  ctx.get("/:owner/:repo/merge-requests/:number/diff", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    let mr = @collaboration.require_merge_request(
      pool,
      scope,
      @web_context.positive_resource_number(
        @web_context.required_param(req, "number", "MR"),
      ),
    )
    let revision = @collaboration.merge_revision(
      pool,
      mr,
      version=@web_context.positive_resource_number(
        req.query().get("version").unwrap_or(mr.version.to_string()),
      ),
    )
    let dir = @repository.resolve_repository_dir(root, scope.repo)
    let comparison = @gitops.revision_comparison(
      dir,
      revision,
      req.query().get("commit").filter(s => !s.is_empty()),
    )
    let result = diff_executor.structured(
      dir,
      comparison.base_sha,
      comparison.head_sha,
      @web_context.structured_diff_options(req),
      page=@web_context.diff_page(req),
      file_id=req.query().get("file_id").unwrap_or(""),
    )
    @repository.authorize_repository(pool, actor, scope.repo, Read)
    res.send_json(result, headers={ "Cache-Control": "no-store" })
  })
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
    let query = req.query().get("q").unwrap_or("")
    let mine = req.query().get("mine").unwrap_or("all")
    guard ["all", "author", "reviews"].contains(mine) else {
      raise @domain.BadRequest(message="invalid merge request filter")
    }
    let rows = @collaboration.list_merge_requests(
      pool,
      scope,
      status,
      page,
      query~,
      author=if mine == "author" { actor.id } else { 0L },
      reviewer=if mine == "reviews" { actor.id } else { 0L },
    )
    let clone = @repository.effective_ssh_endpoint(pool, addresses).map(endpoint => {
      endpoint.clone_url(scope.repo)
    })
    res.send_html(
      render_merge_list(
        assets,
        actor,
        scope,
        rows,
        @collaboration.merge_list_metadata(pool, scope, rows),
        query,
        mine,
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
        @collaboration.prepare_merge_checks(pool, scope, mr)
      } catch {
        @domain.BadRequest(message~) | @gitops.Failure(message~) =>
          stale = message
        err => raise err
      }
    }
    let code = req
      .query()
      .get("code")
      .map(@web_context.positive_resource_number)
    let requested_discussion = if code is Some(_) {
      code
    } else {
      req.query().get("discussion").map(@web_context.positive_resource_number)
    }
    let mut anchor_error = ""
    let discussion_filter = req.query().get("filter").unwrap_or("all")
    guard ["all", "unresolved", "resolved"].contains(discussion_filter) else {
      raise @domain.BadRequest(message="invalid discussion filter")
    }
    if requested_discussion is Some(id) {
      let discussion = @collaboration.merge_discussion(
        pool, scope, actor, mr, id,
      )
      if discussion.anchor is Some(anchor) {
        let mut file_page = @web_context.diff_page(req)
        let mut file_id = req.query().get("file_id").unwrap_or("")
        if diff_enabled && (code is Some(_) || !req.query().has("page")) {
          try {
            match diff_executor.locate_anchor(git_dir, anchor) {
              Some((manifest, id)) => {
                file_page = manifest.page
                file_id = id
              }
              None =>
                anchor_error = "The commented file is unavailable in this comparison. The saved discussion context is shown below."
            }
          } catch {
            @gitops.DiffFailure(message) => anchor_error = message
            err => raise err
          }
        }
        @repository.authorize_repository(pool, actor, scope.repo, Read)
        if req.query().get("tab") != Some("changes") ||
          req.query().get("discussion") != Some(id.to_string()) ||
          req.query().get("version") != Some(discussion.version.to_string()) ||
          req.query().get("commit").unwrap_or("") != anchor.commit_sha ||
          file_page != @web_context.diff_page(req) ||
          file_id != req.query().get("file_id").unwrap_or("") {
          let comment = req
            .query()
            .get("comment")
            .map(@web_context.positive_resource_number)
          let discussion_page = @web_context.positive_resource_number(
            req.query().get("discussion_page").unwrap_or("1"),
          )
          let commit_page = @web_context.positive_resource_number(
            req.query().get("commit_page").unwrap_or("1"),
          )
          let options = @web_context.structured_diff_options(req)
          let target = StringBuilder()
          target.write_string(
            "\{@web_ui.repo_link(scope.repo)}/merge-requests/\{mr.number}?tab=changes&version=\{discussion.version}&commit=\{anchor.commit_sha}&discussion=\{id}&discussion_page=\{discussion_page}&commit_page=\{commit_page}&filter=\{discussion_filter}",
          )
          // Preserve an omitted file page on errors so a refresh retries locating
          // notification/legacy links, without creating a redirect loop.
          if anchor_error.is_empty() || req.query().has("page") {
            target.write_string("&page=\{file_page}")
          }
          if file_id.length() == 64 &&
            file_id
            .iter()
            .all(c => c.is_ascii_digit() || (c >= 'a' && c <= 'f')) {
            target.write_string("&file_id=\{file_id}")
          }
          target.write_string(
            "&mode=\{options.mode}&ignore_comments=\{(options.ignore_comments).to_string()}&ignore_tests=\{(options.ignore_tests).to_string()}",
          )
          if comment is Some(comment) {
            target.write_string("&comment=\{comment}")
          }
          if code is Some(code) {
            target.write_string("&code=\{code}#diff-code")
          } else {
            target.write_string(
              comment.map(id => "#comment-\{id}").unwrap_or("#discussion-\{id}"),
            )
          }
          res.send_void(
            status=303,
            headers=@web_context.private_page_headers(
              location=target.to_string(),
            ),
          )
          return
        }
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
    let selected_commit = req
      .query()
      .get("commit")
      .filter(value => !value.is_empty())
    guard selected_commit is None || tab == "changes" else {
      raise @domain.BadRequest(
        message="commit selection requires the Changes view",
      )
    }
    let commit_page = match req.query().get("commit_page") {
      Some(value) => @web_context.positive_resource_number(value)
      None => 1L
    }
    let selected_discussion = req
      .query()
      .get("discussion")
      .map(@web_context.positive_resource_number)
    let selected_comment = req
      .query()
      .get("comment")
      .map(@web_context.positive_resource_number)
    let discussion_page = match selected_comment {
      Some(comment) => {
        guard selected_discussion is Some(discussion) else {
          raise @domain.BadRequest(
            message="comment target requires a discussion",
          )
        }
        @collaboration.merge_discussion_comment_page(
          pool, scope, actor, mr, discussion, comment,
        )
      }
      None =>
        @web_context.positive_resource_number(
          req.query().get("discussion_page").unwrap_or("1"),
        )
    }
    let mut comparison : @gitops.RevisionComparison? = None
    let mut patch = ""
    let mut diff_error = anchor_error
    let mut structured_view : @moonback.Html? = None
    let mut diff_toolbar : @moonback.Html? = None
    let mut commits : Array[@gitops.CommitInfo] = []
    if revision is Some(revision) {
      if tab == "changes" || tab == "commits" {
        commits = @gitops.revision_commits(git_dir, revision, commit_page)
      }
      if tab == "changes" {
        let selected = @gitops.revision_comparison(
          git_dir, revision, selected_commit,
        )
        comparison = Some(selected)
        if anchor_error.is_empty() {
          try {
            if diff_enabled {
              let options = @web_context.structured_diff_options(req)
              let manifest = diff_executor.manifest(
                git_dir,
                selected.base_sha,
                selected.head_sha,
                page=@web_context.diff_page(req),
              )
              let file = match
                req.query().get("file_id").filter(id => !id.is_empty()) {
                Some(id) =>
                  Some(diff_executor.file(git_dir, manifest, id, options))
                None => None
              }
              let base = "\{@web_ui.repo_link(scope.repo)}/merge-requests/\{mr.number}"
              let query = "?version=\{revision.version}&commit=\{selected_commit.unwrap_or("")}"
              let page_url = base +
                query +
                "&tab=changes&discussion_page=\{discussion_page}&commit_page=\{commit_page}&filter=\{discussion_filter}" +
                selected_discussion.map(id => "&discussion=\{id}").unwrap_or("") +
                selected_comment.map(id => "&comment=\{id}").unwrap_or("")
              let view_url = page_url +
                "&page=\{manifest.page}" +
                file.map(result => "&file_id=\{result.file.id}").unwrap_or("") +
                code.map(id => "&code=\{id}").unwrap_or("")
              structured_view = Some(
                @web_ui.render_structured_diff(
                  manifest,
                  file,
                  options,
                  base + "/diff" + query,
                  page_url,
                  view_url~,
                  toolbar_target="mr-diff-toolbar",
                ),
              )
              diff_toolbar = Some(
                @moonback.Html(b => {
                  b <+
                    "<moonhub-diff-toolbar id=\"mr-diff-toolbar\"><div data-toolbar-fallback>\{@web_ui.render_diff_options(options, view_url)}</div></moonhub-diff-toolbar>"
                }),
              )
            } else {
              patch = @gitops.merge_git(git_dir, [
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--find-renames",
                "--unified=3",
                "--no-color",
                selected.base_sha,
                selected.head_sha,
                "--",
              ])
            }
          } catch {
            @domain.BadRequest(message~)
            | @gitops.Failure(message~)
            | @gitops.DiffFailure(message) => diff_error = message
            err => raise err
          }
        }
      }
    }
    @repository.authorize_repository(pool, actor, scope.repo, Read)
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
    let discussions = match selected_discussion {
      Some(id) =>
        [
          @collaboration.merge_discussion(
            pool,
            scope,
            actor,
            mr,
            id,
            page=discussion_page,
          ),
        ]
      None =>
        @collaboration.list_merge_discussions(
          pool,
          scope,
          actor,
          mr,
          discussion_page,
          filter=discussion_filter,
          anchor_version=if tab == "changes" { selected } else { 0L },
          comparison~,
        )
    }
    let unresolved = @collaboration.unresolved_merge_discussions(
      pool, scope, actor, mr,
    )
    let (approved, _) = @collaboration.merge_review_counts(pool, scope, mr)
    let clone = @repository.effective_ssh_endpoint(pool, addresses).map(endpoint => {
      endpoint.clone_url(scope.repo)
    })
    let checks = @collaboration.merge_checks(pool, mr, version=selected)
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
        discussions,
        discussion_filter,
        selected_discussion,
        discussion_page,
        unresolved,
        commits,
        commit_page,
        comparison,
        patch,
        diff_error,
        structured_view,
        blocker,
        approved,
        @collaboration.required_merge_approvals(pool, scope, mr.target),
        @collaboration.merge_self_approval_allowed(pool, mr),
        @repository.can_access_repository(
          pool,
          actor,
          scope.repo,
          @repository.Write,
        ),
        @identity.can_manage_team(pool, actor, scope.team_id),
        @web_context.request_form_token(req, "merge-requests"),
        clone,
        checks,
        @collaboration.review_requests(pool, actor, scope, mr),
        @collaboration.review_candidates(pool, actor, scope, mr),
        @collaboration.thread_subscription(pool, actor, scope, mr.id, false),
        @web_context.request_form_token(req, "notifications"),
        diff_toolbar~,
        branches=if mr.status == "open" {
          @domain.split_lines(
            @gitops.merge_git(git_dir, [
              "for-each-ref", "--format=%(refname:strip=2)", "--count=1000", "refs/heads/",
            ]),
          )
        } else {
          []
        },
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
    let mut discussion = form
      .get("discussion")
      .map(@web_context.positive_resource_number)
    let mut reply_page = 1L
    let mut reply_id : Int64? = None
    let mut inline_error : String? = None
    try {
      let prepared = if action == "inline-comment" {
        let scope = @repository.repository_scope(pool, actor, repo)
        let git_dir = @repository.resolve_repository_dir(root, repo)
        let mr = @collaboration.require_merge_request(pool, scope, number)
        Some(
          @collaboration.prepare_anchored_merge_discussion(
            pool,
            scope,
            actor,
            mr,
            git_dir,
            @web_context.positive_resource_number(
              form.get("version").unwrap_or(""),
            ),
            form.get("commit").filter(value => !value.is_empty()),
            form.get("path").unwrap_or(""),
            form.get("side").unwrap_or(""),
            @web_context.positive_resource_number(
              form.get("start_line").unwrap_or(""),
            ),
            @web_context.positive_resource_number(
              form.get("end_line").unwrap_or(""),
            ),
            form.get("body").unwrap_or(""),
            structured?=@web_context.diff_selection(form).map(selection => {
              (diff_executor, selection)
            }),
          ),
        )
      } else {
        None
      }
      @repository.with_repository_write(pool, root, actor, repo, (
        scope,
        git_dir,
      ) => {
        let mr = @collaboration.require_merge_request(pool, scope, number)
        if action == "inline-comment" {
          let created = @collaboration.create_prepared_merge_discussion(
            pool,
            scope,
            actor,
            mr,
            prepared.unwrap(),
          )
          discussion = Some(created)
          reply_id = Some(created)
        } else if action == "reply" {
          reply_id = Some(
            @collaboration.reply_merge_discussion(
              pool,
              scope,
              actor,
              mr,
              @web_context.positive_resource_number(
                form.get("discussion").unwrap_or(""),
              ),
              form.get("body").unwrap_or(""),
            ),
          )
          let thread = @collaboration.merge_discussion(
            pool,
            scope,
            actor,
            mr,
            discussion.unwrap(),
          )
          reply_page = (thread.reply_count - 1L) / 50L + 1L
        } else if action == "resolve-discussion" ||
          action == "reopen-discussion" {
          @collaboration.set_merge_discussion_resolved(
            pool,
            scope,
            actor,
            mr,
            @web_context.positive_resource_number(
              form.get("discussion").unwrap_or(""),
            ),
            @web_context.positive_resource_number(
              form.get("state_version").unwrap_or(""),
            ),
            action == "resolve-discussion",
          )
        } else if action == "delete-comment" || action == "restore-comment" {
          let comment = @web_context.positive_resource_number(
            form.get("comment").unwrap_or(""),
          )
          if discussion is Some(id) {
            reply_page = @collaboration.merge_discussion_comment_page(
              pool, scope, actor, mr, id, comment,
            )
            reply_id = Some(comment)
          }
          @collaboration.set_merge_comment_deleted(
            pool,
            scope,
            actor,
            mr,
            @web_context.positive_resource_number(
              form.get("comment").unwrap_or(""),
            ),
            @web_context.positive_resource_number(
              form.get("version").unwrap_or(""),
            ),
            action == "delete-comment",
          )
        } else if action == "retarget" {
          @collaboration.update_merge_request(
            pool,
            scope,
            git_dir,
            actor,
            mr,
            mr.title,
            mr.description,
            form.get("target").unwrap_or(""),
            @web_context.positive_resource_number(
              form.get("edit_version").unwrap_or(""),
            ),
            authorize_checks=true,
          )
        } else if action == "request-review" {
          let current = @collaboration.refresh_merge_request(
            pool, scope, git_dir, mr,
          )
          @collaboration.request_merge_review(
            pool,
            actor,
            scope,
            current,
            @web_context.positive_resource_number(
              form.get("reviewer").unwrap_or(""),
            ),
            @web_context.positive_resource_number(
              form.get("version").unwrap_or(""),
            ),
          )
        } else if action == "review" ||
          action == "merge" ||
          action == "approve-checks" {
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
            @collaboration.enqueue_merge(
              pool,
              scope,
              actor,
              mr,
              version,
              edit_version=form
                .get("edit_version")
                .map(@web_context.positive_resource_number),
            )
          } else if action == "approve-checks" {
            @collaboration.approve_merge_checks(pool, scope, actor, mr, version)
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
          if action == "ready" || action == "reopen" {
            let current = @collaboration.refresh_merge_request(
              pool,
              scope,
              git_dir,
              @collaboration.require_merge_request(pool, scope, number),
            )
            @collaboration.prepare_merge_checks(pool, scope, current, actor~)
          }
        }
      })
    } catch {
      @domain.BadRequest(message~) =>
        if action == "inline-comment" || action == "retarget" {
          inline_error = Some(message)
        } else {
          raise @domain.BadRequest(message~)
        }
      err =>
        if action == "retarget" {
          match err {
            @gitops.Failure(message~) => inline_error = Some(message)
            _ => raise err
          }
        } else {
          raise err
        }
    }
    if inline_error is Some(_) && action == "retarget" {
      let scope = @repository.repository_scope(pool, actor, repo)
      let mr = @collaboration.require_merge_request(pool, scope, number)
      let git_dir = @repository.resolve_repository_dir(root, repo)
      let branches = @domain.split_lines(
        @gitops.merge_git(git_dir, [
          "for-each-ref", "--format=%(refname:strip=2)", "--count=1000", "refs/heads/",
        ]),
      )
      let base = "\{@web_ui.repo_link(repo)}/merge-requests/\{number}"
      res.send_html(
        @web_ui.layout(
          "Change target branch",
          assets,
          Html(b => {
            b <+
              "<a href=\"\{base}\">Back to merge request</a><h1>Change target branch</h1>"
            b <+
              "\{render_merge_target_form(base, @web_context.request_form_token(req, "merge-requests"), branches, mr.source, form.get("target").unwrap_or(""), form.get("edit_version").unwrap_or(""), inline_error)}"
          }),
          current_user=Some(actor),
          navigation=@web_ui.RepositoryNavigation(
            repo,
            "merge-requests",
            @identity.can_manage_team(pool, actor, scope.team_id),
          ),
        ),
        status=400,
        headers=@web_context.private_page_headers(),
      )
      return
    }
    if inline_error is Some(_) {
      let scope = @repository.repository_scope(pool, actor, repo)
      let base = "\{@web_ui.repo_link(repo)}/merge-requests/\{number}"
      let version = form.get("version").unwrap_or("")
      let commit = form.get("commit").unwrap_or("")
      res.send_html(
        @web_ui.layout(
          "Comment on code",
          assets,
          Html(b => {
            b <+
              "<a href=\"\{base}?tab=changes&amp;version=\{@web_context.url_escape_path(version)}&amp;commit=\{@web_context.url_escape_path(commit)}\">Back to changes</a><h1>Comment on code</h1>"
            b <+
              "\{render_inline_composer(base, @web_context.request_form_token(req, "merge-requests"), version, commit, form, inline_error)}"
          }),
          current_user=Some(actor),
          navigation=@web_ui.RepositoryNavigation(
            scope.repo,
            "merge-requests",
            @identity.can_manage_team(pool, actor, scope.team_id),
          ),
        ),
        status=400,
        headers=@web_context.private_page_headers(),
      )
      return
    }
    let location = "\{@web_ui.repo_link(repo)}/merge-requests/\{number}" +
      (match discussion {
        Some(id) =>
          match reply_id {
            Some(reply) =>
              "?discussion=\{id}&discussion_page=\{reply_page}&comment=\{reply}#comment-\{reply}"
            None => "?discussion=\{id}#discussion-\{id}"
          }
        None => ""
      })
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(location~),
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
        allow_self_approval=form.get("allow_self_approval") == Some("on"),
        checks=@domain.split_lines(form.get("checks").unwrap_or(""))
          .map(path => path.trim().to_owned())
          .filter(path => !path.is_empty()),
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
