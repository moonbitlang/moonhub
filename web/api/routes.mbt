///|
pub let api_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  ctx.get(
    "/user",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      {
        "id": actor.id.to_string(),
        "username": actor.name_key,
        "display_name": actor.display_name,
      }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/mrs",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let status = req.query().get("status").unwrap_or("open")
      guard ["open", "closed", "merged"].contains(status) else {
        raise @domain.BadRequest(message="invalid MR status")
      }
      let rows = @collaboration.list_merge_requests(
        pool,
        scope,
        status,
        page(req),
      )
      {
        "items": rows[:Int32::min(50, rows.length())].to_owned().map(mr_json),
        "has_more": rows.length() > 50,
      }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/mrs",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let body = api_body(req, [
        "title", "description", "source", "target", "draft", "issue",
      ])
      @repository.with_repository_write(
        pool,
        root,
        actor,
        @web_context.repo_param(req),
        (scope, git_dir) => {
          let draft = field(body, "draft", fallback="false")
          guard ["true", "false"].contains(draft) else {
            raise @domain.BadRequest(message="draft must be true or false")
          }
          let mr = @collaboration.create_merge_request(
            pool,
            scope,
            git_dir,
            actor,
            field(body, "title"),
            field(body, "description", fallback=""),
            field(body, "source"),
            field(body, "target"),
            draft == "true",
            issue=number(field(body, "issue", fallback="0"), zero=true),
            authorize_checks=false,
          )
          mr_json(mr)
        },
      )
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/mrs/:number",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let mr = @collaboration.require_merge_request(
        pool,
        scope,
        number(@web_context.required_param(req, "number", "MR")),
      )
      let rows = @collaboration.list_merge_activity(pool, mr, page(req))
      let activities = rows[:Int32::min(50, rows.length())]
        .to_owned()
        .map(a => activity_json(a))
      {
        "mr": mr_json(mr),
        "reviewers": @collaboration.review_requests(pool, actor, scope, mr).map(person => {
            (
              {
                "id": person.user_id.to_string(),
                "name": person.display_name,
                "pending": person.pending,
                "version": person.version.to_string(),
              } : Json)
          },
        ),
        "review_candidates": @collaboration.review_candidates(
          pool, actor, scope, mr,
        ).map(person => {
          (
            {
              "id": person.id.to_string(),
              "username": person.name_key,
              "name": person.display_name,
            } : Json)
        }),
        "checks": @collaboration.merge_checks(pool, mr).map(check_json),
        "has_more": rows.length() > 50,
        "activity": activities,
        "unresolved_discussions": @collaboration.unresolved_merge_discussions(
          pool, scope, actor, mr,
        ).to_string(),
      }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/mrs/:number/discussions",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let mr = @collaboration.require_merge_request(
        pool,
        scope,
        number(@web_context.required_param(req, "number", "MR")),
      )
      let current_page = page(req)
      match req.query().get("discussion") {
        Some(id) => {
          let discussion = @collaboration.merge_discussion(
            pool,
            scope,
            actor,
            mr,
            number(id),
            page=current_page,
          )
          {
            "discussion": discussion_json(discussion),
            "has_more": current_page * 50L < discussion.reply_count,
          }
        }
        None => {
          let rows = @collaboration.list_merge_discussions(
            pool,
            scope,
            actor,
            mr,
            current_page,
            filter=req.query().get("filter").unwrap_or("all"),
          )
          {
            "items": rows[:Int32::min(50, rows.length())]
            .to_owned()
            .map(d => discussion_json(d, preview=true)),
            "has_more": rows.length() > 50,
            "unresolved_count": @collaboration.unresolved_merge_discussions(
              pool, scope, actor, mr,
            ).to_string(),
          }
        }
      }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/mrs/:number/diff",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let mr = @collaboration.require_merge_request(
        pool,
        scope,
        number(@web_context.required_param(req, "number", "MR")),
      )
      let selected = number(
        req.query().get("version").unwrap_or(mr.version.to_string()),
      )
      let revision = @collaboration.merge_revision(pool, mr, version=selected)
      let git_dir = @repository.resolve_repository_dir(root, scope.repo)
      let patch = @gitops.merge_git(git_dir, [
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--find-renames",
        revision.base_sha,
        revision.source_sha,
        "--",
      ])
      @repository.authorize_repository(pool, actor, scope.repo, Read)
      {
        "version": selected.to_string(),
        "source_sha": revision.source_sha,
        "target_sha": revision.target_sha,
        "patch": patch,
      }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/mrs/:number/checks",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let mr = @collaboration.require_merge_request(
        pool,
        scope,
        number(@web_context.required_param(req, "number", "MR")),
      )
      {
        "version": mr.version.to_string(),
        "checks": @collaboration.merge_checks(pool, mr).map(check_json),
      }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/mrs/:number/:action",
    api_handler(req => {
      let action = @web_context.required_param(req, "action", "action")
      let permission = if action == "merge" {
        "merge"
      } else if action == "approve-checks" {
        "execute"
      } else {
        "write"
      }
      let actor = api_actor(pool, req, permission)
      let body = api_body(
        req,
        match action {
          "reply" => ["discussion", "body"]
          "resolve-discussion" | "reopen-discussion" =>
            ["discussion", "state_version"]
          "edit" => ["edit_version", "title", "description"]
          "delete-comment" | "restore-comment" => ["version", "comment"]
          _ => ["version", "decision", "body", "reviewer", "edit_version"]
        },
      )
      let id = number(@web_context.required_param(req, "number", "MR"))
      @repository.with_repository_write(
        pool,
        root,
        actor,
        @web_context.repo_param(req),
        (scope, git_dir) => {
          let mr = @collaboration.require_merge_request(pool, scope, id)
          let current = if [
              "comment", "edit", "delete-comment", "restore-comment", "reply", "resolve-discussion",
              "reopen-discussion",
            ].contains(action) {
            mr
          } else {
            @collaboration.refresh_merge_request(pool, scope, git_dir, mr)
          }
          let mut reply_id : Int64? = None
          match action {
            "reply" =>
              reply_id = Some(
                @collaboration.reply_merge_discussion(
                  pool,
                  scope,
                  actor,
                  current,
                  number(field(body, "discussion")),
                  field(body, "body"),
                ),
              )
            "resolve-discussion" | "reopen-discussion" =>
              @collaboration.set_merge_discussion_resolved(
                pool,
                scope,
                actor,
                current,
                number(field(body, "discussion")),
                number(field(body, "state_version")),
                action == "resolve-discussion",
              )
            "edit" => {
              guard body.contains("title") || body.contains("description") else {
                raise @domain.BadRequest(
                  message="MR edit requires title or description",
                )
              }
              @collaboration.edit_merge_request(
                pool,
                scope,
                actor,
                current,
                "edit",
                field(body, "title", fallback=current.title),
                field(body, "description", fallback=current.description),
                expected=number(field(body, "edit_version")),
              )
            }
            "delete-comment" | "restore-comment" =>
              @collaboration.set_merge_comment_deleted(
                pool,
                scope,
                actor,
                current,
                number(field(body, "comment")),
                number(field(body, "version")),
                action == "delete-comment",
              )
            "review" | "comment" =>
              @collaboration.submit_merge_review(
                pool,
                actor,
                current,
                number(field(body, "version")),
                if action == "comment" {
                  "comment"
                } else {
                  field(body, "decision")
                },
                field(body, "body", fallback=""),
              )
            "request-review" =>
              @collaboration.request_merge_review(
                pool,
                actor,
                scope,
                current,
                number(field(body, "reviewer")),
                number(field(body, "version")),
              )
            "merge" =>
              @collaboration.enqueue_merge(
                pool,
                scope,
                actor,
                current,
                number(field(body, "version")),
              )
            "approve-checks" =>
              @collaboration.approve_merge_checks(
                pool,
                scope,
                actor,
                current,
                number(field(body, "version")),
              )
            "close" | "reopen" | "draft" | "ready" => {
              @collaboration.edit_merge_request(
                pool,
                scope,
                actor,
                current,
                action,
                "",
                "",
                expected=number(field(body, "edit_version")),
              )
              if action == "reopen" {
                // Observe the reopened source before releasing the repository
                // lock; a subsequent push is a separate synchronize event.
                ignore(
                  @collaboration.refresh_merge_request(
                    pool,
                    scope,
                    git_dir,
                    @collaboration.require_merge_request(pool, scope, id),
                  ),
                )
              }
            }
            _ => raise @domain.BadRequest(message="unsupported MR action")
          }
          if ["reply", "resolve-discussion", "reopen-discussion"].contains(
              action,
            ) {
            {
              "reply_id": reply_id.map(id => id.to_string()).unwrap_or(""),
              "discussion": discussion_json(
                @collaboration.merge_discussion(
                  pool,
                  scope,
                  actor,
                  current,
                  number(field(body, "discussion")),
                ),
              ),
            }
          } else {
            mr_json(@collaboration.require_merge_request(pool, scope, id))
          }
        },
      )
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/issues",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let status = req.query().get("status").unwrap_or("open")
      guard ["open", "closed"].contains(status) else {
        raise @domain.BadRequest(message="invalid Issue status")
      }
      let rows = @collaboration.list_issues(
        pool,
        scope,
        status,
        page(req),
        req.query().get("assigned") == Some("me"),
        actor.id,
        req.query().get("q").unwrap_or(""),
      )
      {
        "items": rows[:Int32::min(50, rows.length())].to_owned().map(issue_json),
        "has_more": rows.length() > 50,
      }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/issues",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let body = api_body(req, ["title", "description", "assignee"])
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let id = @collaboration.create_issue(
        pool,
        scope,
        actor,
        field(body, "title"),
        field(body, "description", fallback=""),
        number(field(body, "assignee", fallback="0"), zero=true),
      )
      issue_json(@collaboration.require_issue(pool, scope, id))
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/issues/:number",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let issue = @collaboration.require_issue(
        pool,
        scope,
        number(@web_context.required_param(req, "number", "Issue")),
      )
      let rows = @collaboration.list_issue_activity(pool, issue, page(req))
      {
        "issue": issue_json(issue),
        "has_more": rows.length() > 50,
        "activity": rows[:Int32::min(50, rows.length())]
        .to_owned()
        .map(a => {
          (
            {
              "actor": a.actor,
              "kind": a.kind,
              "body": a.body,
              "created_at": a.created_at,
            } : Json)
        }),
      }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/issues/:number/:action",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let issue = @collaboration.require_issue(
        pool,
        scope,
        number(@web_context.required_param(req, "number", "Issue")),
      )
      let action = @web_context.required_param(req, "action", "action")
      guard ["comment", "close", "reopen", "edit"].contains(action) else {
        raise @domain.BadRequest(message="unsupported Issue action")
      }
      let body = api_body(req, [
        "edit_version", "title", "description", "assignee", "body",
      ])
      @collaboration.mutate_issue(
        pool,
        scope,
        actor,
        issue,
        if action == "comment" {
          issue.edit_version
        } else {
          number(field(body, "edit_version"))
        },
        action,
        field(body, "title", fallback=issue.title),
        field(body, "description", fallback=issue.description),
        number(
          field(body, "assignee", fallback=issue.assignee_id.to_string()),
          zero=true,
        ),
        field(body, "body", fallback=""),
      )
      issue_json(@collaboration.require_issue(pool, scope, issue.number))
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/runs",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      {
        "items": @pipeline.list_runs(pool, actor, @web_context.repo_param(req))
        .iter()
        .take(50)
        .map(run_json)
        .collect(),
      }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/runs/:number",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let repo = @web_context.repo_param(req)
      let id = number(@web_context.required_param(req, "number", "run"))
      {
        "run": run_json(@pipeline.get_run(pool, actor, repo, id)),
        "jobs": @pipeline.list_jobs(pool, actor, repo, id).map(job => {
          (
            {
              "key": job.job_key,
              "status": match job.state {
                Waiting => "waiting"
                Queued => "queued"
                Leased => "leased"
                Running => "running"
                Completed => "completed"
              },
              "conclusion": conclusion_json(job.conclusion),
              "attempt": job.attempt_id.map(id => id.to_string()).unwrap_or(""),
            } : Json)
        }),
      }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/runs",
    api_handler(req => {
      let actor = api_actor(pool, req, "execute")
      let body = api_body(req, ["branch", "workflow"])
      run_json(
        @pipeline.create_run(
          pool,
          root,
          actor,
          @web_context.repo_param(req),
          field(body, "branch"),
          field(body, "workflow"),
        ),
      )
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/runs/:number/:action",
    api_handler(req => {
      let actor = api_actor(pool, req, "execute")
      ignore(api_body(req, []))
      let repo = @web_context.repo_param(req)
      let id = number(@web_context.required_param(req, "number", "run"))
      match @web_context.required_param(req, "action", "action") {
        "rerun" => run_json(@pipeline.rerun_run(pool, root, actor, repo, id))
        "cancel" => {
          coordinator.cancel_run(actor, repo, id)
          run_json(@pipeline.get_run(pool, actor, repo, id))
        }
        _ => raise @domain.BadRequest(message="unsupported CI action")
      }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/runs/:number/logs/:attempt",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let logs = coordinator.read_log_page(
        actor,
        @web_context.repo_param(req),
        number(@web_context.required_param(req, "number", "run")),
        number(@web_context.required_param(req, "attempt", "attempt")),
        after=number(req.query().get("after").unwrap_or("0"), zero=true),
      )
      {
        "chunks": logs.chunks.map(chunk => {
          (
            {
              "id": chunk.id,
              "step": chunk.step_id,
              "stream": chunk.stream,
              "text": chunk.text,
            } : Json)
        }),
        "next_cursor": logs.next_cursor,
        "has_more": logs.has_more,
        "complete": logs.complete,
      }
    }),
  )
  ctx.get(
    "/inbox",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let rows = @collaboration.inbox_items(
        pool,
        actor,
        req.query().get("filter").unwrap_or("unread"),
        page(req),
      )
      {
        "unread": @collaboration.unread_notification_count(pool, actor).to_string(),
        "has_more": rows.length() > 50,
        "items": rows[:Int32::min(50, rows.length())]
        .to_owned()
        .map(item => {
          (
            {
              "id": item.id.to_string(),
              "repository": item.repo.path(),
              "number": item.number.to_string(),
              "title": item.title,
              "kind": item.kind,
              "read": item.read,
              "discussion_id": item.discussion_id
              .map(id => id.to_string())
              .unwrap_or(""),
              "comment_id": item.comment_id
              .map(id => id.to_string())
              .unwrap_or(""),
              "url": item.url(),
            } : Json)
        }),
      }
    }),
  )
  ctx.post(
    "/inbox/:number/read",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      ignore(api_body(req, []))
      let item = @collaboration.mark_notification_read(
        pool,
        actor,
        number(@web_context.required_param(req, "number", "notification")),
      )
      { "url": item.url() }
    }),
  )
})
