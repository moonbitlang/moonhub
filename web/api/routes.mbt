///|
pub let api_module : @moonback.Module = Module(ctx => {
  ctx.use_(job_actions_api_module)
  let diff_executor = ctx.require(@web_context.diff_executor_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  let git_binary = ctx.require(@web_context.job_git_binary_key)
  for advertise in [true, false] {
    let handler : @moonback.Handler = (req, res) => {
      let bytes = try {
        let token = release_token(req)
        guard token is Some(token) else {
          raise @domain.Unauthorized(
            message="job Git bearer credential required",
          )
        }
        ignore(
          coordinator.authenticate_job_api(
            token,
            @web_context.repo_param(req),
            "git:write",
          ),
        )
        if advertise {
          guard req.query().get("service") == Some("git-receive-pack") else {
            raise @domain.BadRequest(message="only receive-pack is supported")
          }
        } else {
          guard req.headers.get("content-type") ==
            Some("application/x-git-receive-pack-request") &&
            req.headers.get("content-encoding") is None else {
            raise @domain.BadRequest(
              message="Git receive-pack content required",
            )
          }
        }
        @pipeline.job_git_exchange(
          pool,
          coordinator,
          root,
          git_binary,
          @web_context.repo_param(req),
          token,
          if advertise {
            b""
          } else {
            @web_context.read_bounded_body(req, 67108864)
          },
          advertise,
        )
      } catch {
        err => {
          let (status, json) = api_error(err)
          res.send_json(json, status~, headers={
            "Cache-Control": "no-store",
            "Connection": "close",
          })
          return
        }
      }
      let writer = res.respond(status=200, headers={
        "Content-Type": if advertise {
          "application/x-git-receive-pack-advertisement"
        } else {
          "application/x-git-receive-pack-result"
        },
        "Cache-Control": "no-store",
        "Content-Length": bytes.length().to_string(),
      })
      writer.write(bytes)
    }
    if advertise {
      ctx.get("/repos/:owner/:repo/git/info/refs", handler)
    } else {
      ctx.post("/repos/:owner/:repo/git/git-receive-pack", handler)
    }
  }
  ctx.get(
    "/repos/:owner/:repo/dependency-grants",
    api_handler(req => {
      "items": @runtime.dependency_grants(
        pool,
        api_actor(pool, req, "read"),
        @web_context.repo_param(req),
      ),
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/dependency-grants",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let body = api_body(req, [
        "kind", "target", "ref", "credential", "version", "delete",
      ])
      @runtime.save_dependency_grant(
        pool,
        actor,
        @web_context.repo_param(req),
        field(body, "kind"),
        field(body, "target"),
        field(body, "ref"),
        match body.get("credential") {
          None | Some(Null) => None
          Some(String(value)) => Some(value)
          _ => raise @domain.BadRequest(message="credential must be a string")
        },
        number(field(body, "version"), zero=true),
        delete=body.get("delete") == Some(Json::boolean(true)),
      )
      { "ok": true }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/environments",
    api_handler(req => {
      "items": ToJson::to_json(
        @runtime.list_deployment_environments(
          pool,
          api_actor(pool, req, "read"),
          @web_context.repo_param(req),
        ),
      ),
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/environments/:environment",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let body = api_body(req, ["version", "reviewers"])
      let reviewers : Array[Int64] = match body.get("reviewers") {
        Some(Array(values)) =>
          values.map(value => {
            match value {
              String(value) => number(value)
              Number(value, ..) if value > 0 &&
                value <= 9007199254740991.0 &&
                value.floor() == value => value.to_int64()
              _ =>
                raise @domain.BadRequest(
                  message="Reviewer IDs must be positive integers.",
                )
            }
          })
        _ =>
          raise @domain.BadRequest(
            message="reviewers must be an array of user IDs.",
          )
      }
      coordinator.save_deployment_environment(
        actor,
        @web_context.repo_param(req),
        @web_context.required_param(req, "environment", "environment"),
        number(field(body, "version"), zero=true),
        reviewers,
      )
      { "ok": true }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/environments/:environment/delete",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let body = api_body(req, ["version"])
      coordinator.delete_deployment_environment(
        actor,
        @web_context.repo_param(req),
        @web_context.required_param(req, "environment", "environment"),
        number(field(body, "version")),
      )
      { "ok": true }
    }),
  )
  for kind in ["variables", "secrets"] {
    ctx.post(
      "/repos/:owner/:repo/environments/:environment/" + kind + "/:name",
      api_handler(req => {
        let actor = api_actor(pool, req, "write")
        let body = api_body(req, ["version", "value"], body_limit=327680)
        @runtime.save_deployment_value(
          pool,
          actor,
          @web_context.repo_param(req),
          @web_context.required_param(req, "environment", "environment"),
          @web_context.required_param(req, "name", "name"),
          match body.get("value") {
            Some(Null) => None
            Some(String(value)) => Some(value)
            _ =>
              raise @domain.BadRequest(
                message="value must be a string, or null to delete.",
              )
          },
          number(field(body, "version"), zero=true),
          secret=kind == "secrets",
        )
        { "ok": true }
      }),
    )
  }
  ctx.post(
    "/repos/:owner/:repo/runs/:number/deployments/:job",
    api_handler(req => {
      let actor = api_actor(pool, req, "execute")
      let body = api_body(req, ["environment_id", "policy_version", "decision"])
      coordinator.review_deployment(
        actor,
        @web_context.repo_param(req),
        number(@web_context.required_param(req, "number", "run")),
        number(@web_context.required_param(req, "job", "job")),
        number(field(body, "environment_id")),
        number(field(body, "policy_version")),
        field(body, "decision"),
      )
      { "ok": true }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/dispatches",
    api_handler(req => {
      let actor = api_actor(pool, req, "execute")
      let body = api_body(
        req,
        ["event_type", "client_payload", "request_id"],
        body_limit=73728,
      )
      let payload = match body.get("client_payload") {
        None => Map([])
        Some(Object(values)) => values
        _ =>
          raise @domain.BadRequest(message="client_payload must be an object")
      }
      {
        "event_id": @pipeline.dispatch_repository_event(
          pool,
          root,
          actor,
          @web_context.repo_param(req),
          field(body, "event_type"),
          payload,
          request_id=match body.get("request_id") {
            None => ""
            Some(String(value)) => value
            _ => raise @domain.BadRequest(message="request_id must be a string")
          },
        ).to_string(),
      }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/variables",
    api_handler(req => {
      let variables = @runtime.list_variables(
        pool,
        api_actor(pool, req, "read"),
        @web_context.repo_param(req),
      )
      { "items": variables.map(@dto.variable_json) }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/variables/:variable",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let repo = @web_context.repo_param(req)
      let name = @web_context.required_param(req, "variable", "variable").to_upper()
      let body = api_body(req, ["value", "version"], body_limit=327680)
      @runtime.save_variable(
        pool,
        actor,
        repo,
        name,
        field(body, "value"),
        number(field(body, "version"), zero=true),
      )
      let variable = @runtime.list_variables(pool, actor, repo)
        .iter()
        .find_first(variable => variable.name == name)
      guard variable is Some(variable) else {
        raise @domain.NotFound(message="Variable changed. Reload its value.")
      }
      @dto.variable_json(variable)
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/variables/:variable/delete",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let body = api_body(req, ["version"])
      @runtime.delete_variable(
        pool,
        actor,
        @web_context.repo_param(req),
        @web_context.required_param(req, "variable", "variable"),
        number(field(body, "version")),
      )
      { "ok": true }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/secrets",
    api_handler(req => {
      let secrets = @runtime.list_secrets(
        pool,
        api_actor(pool, req, "read"),
        @web_context.repo_param(req),
      )
      { "items": secrets.map(@dto.secret_json) }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/secrets/:secret",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let repo = @web_context.repo_param(req)
      let name = @web_context.required_param(req, "secret", "secret").to_upper()
      let scope = @repository.repository_scope(pool, actor, repo)
      let body = api_body(req, ["value", "branch", "workflow", "version"])
      @runtime.save_secret(
        pool,
        root,
        actor,
        scope,
        name,
        if body.contains("value") {
          Some(field(body, "value"))
        } else {
          None
        },
        field(body, "branch"),
        field(body, "workflow"),
        number(field(body, "version"), zero=true),
      )
      let secret = @runtime.list_secrets(pool, actor, repo)
        .iter()
        .find_first(secret => secret.name == name)
      guard secret is Some(secret) else {
        raise @domain.NotFound(message="Secret changed. Reload its metadata.")
      }
      @dto.secret_json(secret)
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/secrets/:secret/delete",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let body = api_body(req, ["version"])
      @runtime.delete_secret(
        pool,
        actor,
        @web_context.repo_param(req),
        @web_context.required_param(req, "secret", "secret"),
        number(field(body, "version")),
      )
      { "ok": true }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/attachments",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      @repository.authorize_repository(pool, actor, scope.repo, Write)
      let bytes = @web_context.read_bounded_body(
        req, @attachments.maximum_attachment_bytes,
      )
      let image = @attachments.upload(
        pool,
        root,
        scope,
        actor,
        req.query().get("filename").unwrap_or("attachment"),
        bytes,
      )
      {
        "id": image.id,
        "url": image.url,
        "filename": image.filename,
        "markdown": @attachments.markdown(image),
        "media_type": image.media_type,
        "byte_size": image.byte_size.to_string(),
      }
    }),
  )
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
        "items": rows[:Int32::min(50, rows.length())]
        .to_owned()
        .map(@dto.mr_json),
        "has_more": rows.length() > 50,
      }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/mrs",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let body = api_body(
        req,
        ["title", "description", "source", "target", "draft", "issue"],
        images=(pool, root, scope, actor),
      )
      @repository.with_repository_write(pool, root, actor, scope, (
        scope,
        git_dir,
      ) => {
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
        @dto.mr_json(mr)
      })
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
        .map(a => @dto.activity_json(a))
      {
        "mr": @dto.mr_json(mr),
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
        "checks": @collaboration.merge_checks(pool, mr).map(@dto.check_json),
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
      if req.query().get("discussion") is Some(id) {
        let discussion = @collaboration.merge_discussion(
          pool,
          scope,
          actor,
          mr,
          number(id),
          page=current_page,
        )
        {
          "discussion": @dto.discussion_json(discussion),
          "has_more": current_page * 50L < discussion.reply_count,
        }
      } else {
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
          .map(d => @dto.discussion_json(d, preview=true)),
          "has_more": rows.length() > 50,
          "unresolved_count": @collaboration.unresolved_merge_discussions(
            pool, scope, actor, mr,
          ).to_string(),
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
      let (reader, git_dir) = @repository.open_repository_read(
        pool,
        root,
        Some(actor),
        scope,
      )
      defer reader.close()
      let comparison = @gitops.revision_comparison(
        git_dir,
        revision,
        req.query().get("commit").filter(value => !value.is_empty()),
      )
      let format = req.query().get("format").unwrap_or("patch")
      guard format == "patch" || format == "structured" else {
        raise @domain.BadRequest(message="invalid diff format")
      }
      if format == "structured" {
        let result = diff_executor.structured(
          git_dir,
          comparison.base_sha,
          comparison.head_sha,
          @web_context.structured_diff_options(req),
          page=@web_context.diff_page(req),
          file_id=req.query().get("file_id").unwrap_or(""),
        )
        ignore(api_actor(pool, req, "read"))
        @repository.authorize_repository(pool, actor, scope.repo, Read)
        if result is Object(fields) {
          fields.set("version", Json(selected.to_string()))
          fields.set("source_sha", Json(revision.source_sha))
          fields.set("target_sha", Json(revision.target_sha))
          fields.set(
            "commit_sha",
            comparison.commit.map(c => Json(c.hash)).unwrap_or(Json::null()),
          )
        }
        return result
      }
      let patch = @gitops.merge_git(git_dir, [
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--find-renames",
        "--unified=3",
        "--no-color",
        comparison.base_sha,
        comparison.head_sha,
        "--",
      ])
      @repository.authorize_repository(pool, actor, scope.repo, Read)
      {
        "version": selected.to_string(),
        "source_sha": revision.source_sha,
        "target_sha": revision.target_sha,
        "target": revision.target_branch,
        "comparison": if comparison.commit is Some(_) {
          "commit"
        } else {
          "all"
        },
        "base_sha": comparison.base_sha,
        "head_sha": comparison.head_sha,
        "commit_sha": comparison.commit
        .map(commit => Json::string(commit.hash))
        .unwrap_or(Json::null()),
        "parent_count": comparison.parent_count,
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
        "checks": @collaboration.merge_checks(pool, mr).map(@dto.check_json),
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
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let body = api_body(
        req,
        match action {
          "inline-comment" =>
            [
              "version", "commit", "path", "side", "start_line", "end_line", "body",
              "document_id", "file_id", "hunk_id", "diff_page", "mode", "ignore_comments",
              "ignore_tests",
            ]
          "reply" => ["discussion", "body"]
          "resolve-discussion" | "reopen-discussion" =>
            ["discussion", "state_version"]
          "edit" => ["edit_version", "title", "description", "target"]
          "delete-comment" | "restore-comment" => ["version", "comment"]
          _ => ["version", "decision", "body", "reviewer", "edit_version"]
        },
        images=(pool, root, scope, actor),
      )
      let id = number(@web_context.required_param(req, "number", "MR"))
      let prepared = if action == "inline-comment" {
        let mr = @collaboration.require_merge_request(pool, scope, id)
        let (reader, git_dir) = @repository.open_repository_read(
          pool,
          root,
          Some(actor),
          scope,
        )
        defer reader.close()
        let selection_fields : Map[String, String] = Map([])
        for
          key in [
            "document_id", "file_id", "hunk_id", "diff_page", "mode", "ignore_comments",
            "ignore_tests",
          ] {
          if body.contains(key) {
            selection_fields.set(key, field(body, key))
          }
        }
        Some(
          @collaboration.prepare_anchored_merge_discussion(
            pool,
            scope,
            actor,
            mr,
            git_dir,
            number(field(body, "version")),
            body
            .get("commit")
            .map(_ => field(body, "commit"))
            .filter(value => !value.is_empty()),
            field(body, "path"),
            field(body, "side"),
            number(field(body, "start_line")),
            number(field(body, "end_line")),
            field(body, "body"),
            structured?=@web_context.diff_selection(selection_fields).map(selection => {
              (diff_executor, selection)
            }),
          ),
        )
      } else {
        None
      }
      @repository.with_repository_write(pool, root, actor, scope, (
        scope,
        git_dir,
      ) => {
        let mr = @collaboration.require_merge_request(pool, scope, id)
        let current = if [
            "comment", "edit", "delete-comment", "restore-comment", "reply", "resolve-discussion",
            "reopen-discussion", "inline-comment",
          ].contains(action) {
          mr
        } else {
          @collaboration.refresh_merge_request(pool, scope, git_dir, mr)
        }
        let mut reply_id : Int64? = None
        let mut created_discussion : Int64? = None
        match action {
          "inline-comment" =>
            created_discussion = Some(
              @collaboration.create_prepared_merge_discussion(
                pool,
                scope,
                actor,
                current,
                prepared.unwrap(),
              ),
            )
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
            guard body.contains("title") ||
              body.contains("description") ||
              body.contains("target") else {
              raise @domain.BadRequest(
                message="MR edit requires title, description or target",
              )
            }
            @collaboration.update_merge_request(
              pool,
              scope,
              git_dir,
              actor,
              current,
              field(body, "title", fallback=current.title),
              field(body, "description", fallback=current.description),
              field(body, "target", fallback=current.target),
              number(field(body, "edit_version")),
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
              edit_version=body
                .get("edit_version")
                .map(value => {
                  guard value is String(value) else {
                    raise @domain.BadRequest(
                      message="edit_version must be a decimal string",
                    )
                  }
                  number(value)
                }),
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
        if created_discussion is Some(id) {
          {
            "discussion": @dto.discussion_json(
              @collaboration.merge_discussion(pool, scope, actor, current, id),
            ),
          }
        } else if ["reply", "resolve-discussion", "reopen-discussion"].contains(
            action,
          ) {
          {
            "reply_id": reply_id.map(id => id.to_string()).unwrap_or(""),
            "discussion": @dto.discussion_json(
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
          @dto.mr_json(@collaboration.require_merge_request(pool, scope, id))
        }
      })
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
        "items": rows[:Int32::min(50, rows.length())]
        .to_owned()
        .map(@dto.issue_json),
        "has_more": rows.length() > 50,
      }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/issues",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      let body = api_body(
        req,
        ["title", "description", "assignee"],
        images=(pool, root, scope, actor),
      )
      let id = @collaboration.create_issue(
        pool,
        scope,
        actor,
        field(body, "title"),
        field(body, "description", fallback=""),
        number(field(body, "assignee", fallback="0"), zero=true),
      )
      @dto.issue_json(@collaboration.require_issue(pool, scope, id))
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
        "issue": @dto.issue_json(issue),
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
      let body = api_body(
        req,
        ["edit_version", "title", "description", "assignee", "body"],
        images=(pool, root, scope, actor),
      )
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
      @dto.issue_json(@collaboration.require_issue(pool, scope, issue.number))
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/runs",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      {
        "items": @runtime.list_runs(pool, actor, @web_context.repo_param(req))
        .iter()
        .take(50)
        .map(@dto.run_json)
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
      let environments = coordinator.job_environments(actor, repo, id)
      {
        "run": @dto.run_json(@runtime.get_run(pool, actor, repo, id)),
        "deployments": ToJson::to_json(
          @runtime.job_deployments(pool, actor, repo, id),
        ),
        "attempts": @runtime.run_attempts(pool, actor, repo, id).map(run => {
          @dto.run_json(run)
        }),
        "jobs": @runtime.list_jobs(pool, actor, repo, id).map(job => {
          (
            {
              "key": job.job_key,
              "environment": ToJson::to_json(environments.get(job.job_key)),
              "status": match job.state {
                Waiting => "waiting"
                Queued => "queued"
                Leased => "leased"
                Running => "running"
                Completed => "completed"
              },
              "conclusion": @dto.conclusion_json(job.conclusion),
              "actual_conclusion": @dto.conclusion_json(job.actual_conclusion),
              "scheduling_error": job.scheduling_error,
              "reused_from": job.reused_from
              .map(id => id.to_string())
              .unwrap_or(""),
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
      // The inputs object may use 65535 bytes before the request wrapper.
      let body = api_body(
        req,
        ["branch", "workflow", "inputs", "jobs"],
        body_limit=73728,
      )
      let inputs : Map[String, Json] = match body.get("inputs") {
        None => Map([])
        Some(Object(values)) => values
        _ => raise @domain.BadRequest(message="inputs must be a JSON object")
      }
      let jobs : Array[String] = if body.get("jobs") is Some(value) {
        @json.from_json(value) catch {
          _ =>
            raise @domain.BadRequest(message="jobs must be an array of job IDs")
        }
      } else {
        []
      }
      @dto.run_json(
        @pipeline.create_run(
          pool,
          root,
          actor,
          @web_context.repo_param(req),
          field(body, "branch"),
          field(body, "workflow"),
          inputs~,
          jobs~,
        ),
      )
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/runs/:number/:action",
    api_handler(req => {
      let actor = api_actor(pool, req, "execute")
      let action = @web_context.required_param(req, "action", "action")
      let body = api_body(
        req,
        if action == "rerun" {
          ["failed_only"]
        } else {
          []
        },
      )
      let failed_only = match body.get("failed_only") {
        None => false
        Some(True) => true
        Some(False) => false
        _ => raise @domain.BadRequest(message="failed_only must be a boolean")
      }
      let repo = @web_context.repo_param(req)
      let id = number(@web_context.required_param(req, "number", "run"))
      match @web_context.required_param(req, "action", "action") {
        "rerun" =>
          @dto.run_json(
            @pipeline.rerun_run(pool, root, actor, repo, id, failed_only~),
          )
        "cancel" => {
          coordinator.cancel_run(actor, repo, id)
          @dto.run_json(@runtime.get_run(pool, actor, repo, id))
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
