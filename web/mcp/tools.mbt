///|
priv struct Tool {
  name : String
  description : String
  permission : String
  required : Array[String]
  optional : Array[String]
}

///|
fn Tool::definition(self : Tool) -> Json {
  let properties : Map[String, Json] = Map([])
  for key in self.required + self.optional {
    properties[key] = { "type": "string" }
  }
  if self.name == "moonhub_create_run" {
    properties["inputs"] = {
      "type": "object",
      "description": "Workflow dispatch input values; defaults and types are validated against the selected revision.",
      "maxProperties": 25,
      "additionalProperties": { "type": ["string", "boolean", "number"] },
    }
  }
  if properties.contains("repository") {
    properties["repository"] = {
      "type": "string",
      "description": "Repository path, owner/name",
    }
  }
  for
    key in [
      "number", "version", "edit_version", "discussion", "state_version", "attempt",
      "page", "assignee", "after", "issue", "reviewer",
    ] {
    if properties.contains(key) {
      properties[key] = {
        "type": "string",
        "description": "Canonical decimal string (not a JSON number)",
      }
    }
  }
  {
    "name": self.name,
    "description": self.description +
    " Requires " +
    self.permission +
    " token permission and existing repository access.",
    "inputSchema": {
      "type": "object",
      "properties": Json(properties),
      "required": self.required,
      "additionalProperties": false,
    },
    "annotations": {
      "readOnlyHint": self.permission == "read",
      "destructiveHint": self.permission != "read",
      "openWorldHint": self.permission == "execute",
    },
  }
}

///|
fn Tool::validate(self : Tool, args : Map[String, Json]) -> Unit raise {
  for key in self.required {
    guard args.contains(key) else {
      raise ProtocolError(400, -32602, "Missing argument: " + key, None)
    }
  }
  for key, value in args {
    guard self.required.contains(key) || self.optional.contains(key) else {
      raise ProtocolError(400, -32602, "Unsupported argument: " + key, None)
    }
    if self.name == "moonhub_create_run" && key == "inputs" {
      guard value is Object(inputs) &&
        inputs.length() <= 25 &&
        inputs
        .values()
        .all(value => {
          match value {
            String(_) | True | False | Number(_, ..) => true
            _ => false
          }
        }) else {
        raise ProtocolError(
          400,
          -32602,
          "inputs must be an object of string, boolean or number values",
          None,
        )
      }
      continue
    }
    guard value is String(_) else {
      raise ProtocolError(
        400,
        -32602,
        "Argument must be a string: " + key,
        None,
      )
    }
  }
}

///|
// One deterministic catalog supplies both discovery and input validation. Tools
// never accept arbitrary URLs, paths, SQL, or commands from the caller.
fn tool_catalog() -> Array[Tool] {
  [
    {
      name: "moonhub_get_user",
      description: "Get the authenticated account.",
      permission: "read",
      required: [],
      optional: [],
    },
    {
      name: "moonhub_list_repositories",
      description: "List repositories visible to the account.",
      permission: "read",
      required: [],
      optional: [],
    },
    {
      name: "moonhub_list_merge_requests",
      description: "List merge requests; status is open (default), closed or merged.",
      permission: "read",
      required: ["repository"],
      optional: ["status", "page"],
    },
    {
      name: "moonhub_get_merge_request",
      description: "Read a merge request, activity and checks, including current version and edit_version.",
      permission: "read",
      required: ["repository", "number"],
      optional: ["page"],
    },
    {
      name: "moonhub_get_merge_request_diff",
      description: "Read the diff for an immutable MR version (defaults to current).",
      permission: "read",
      required: ["repository", "number"],
      optional: [
        "version", "commit", "format", "file_id", "page", "mode", "ignore_comments",
        "ignore_tests",
      ],
    },
    {
      name: "moonhub_get_merge_request_checks",
      description: "Read checks for the current MR version.",
      permission: "read",
      required: ["repository", "number"],
      optional: [],
    },
    {
      name: "moonhub_list_merge_discussions",
      description: "List MR discussions, or read a full discussion by ID; page selects the list page or the 50-reply detail page. filter is all (default), unresolved or resolved.",
      permission: "read",
      required: ["repository", "number"],
      optional: ["page", "filter", "discussion"],
    },
    {
      name: "moonhub_list_issues",
      description: "List issues; status is open (default) or closed; assigned may be me.",
      permission: "read",
      required: ["repository"],
      optional: ["status", "page", "q", "assigned"],
    },
    {
      name: "moonhub_get_issue",
      description: "Read an issue and activity, including its edit_version.",
      permission: "read",
      required: ["repository", "number"],
      optional: ["page"],
    },
    {
      name: "moonhub_list_runs",
      description: "List up to 50 recent CI runs.",
      permission: "read",
      required: ["repository"],
      optional: [],
    },
    {
      name: "moonhub_get_run",
      description: "Read a CI run and its job attempt IDs.",
      permission: "read",
      required: ["repository", "number"],
      optional: [],
    },
    {
      name: "moonhub_get_run_logs",
      description: "Read a bounded CI log page; after defaults to 0.",
      permission: "read",
      required: ["repository", "number", "attempt"],
      optional: ["after"],
    },
    {
      name: "moonhub_list_inbox",
      description: "Read notifications; filter defaults to unread.",
      permission: "read",
      required: [],
      optional: ["filter", "page"],
    },
    {
      name: "moonhub_mark_notification_read",
      description: "Mark an owned notification read.",
      permission: "write",
      required: ["number"],
      optional: [],
    },
    {
      name: "moonhub_create_issue",
      description: "Create an issue; assignee defaults to 0 (unassigned).",
      permission: "write",
      required: ["repository", "title"],
      optional: ["description", "assignee"],
    },
    {
      name: "moonhub_comment_issue",
      description: "Add an issue comment.",
      permission: "write",
      required: ["repository", "number", "body"],
      optional: [],
    },
    {
      name: "moonhub_edit_issue",
      description: "Edit an issue using the last observed edit_version.",
      permission: "write",
      required: ["repository", "number", "edit_version"],
      optional: ["title", "description", "assignee"],
    },
    {
      name: "moonhub_close_issue",
      description: "Close an issue using the last observed edit_version.",
      permission: "write",
      required: ["repository", "number", "edit_version"],
      optional: [],
    },
    {
      name: "moonhub_reopen_issue",
      description: "Reopen an issue using the last observed edit_version.",
      permission: "write",
      required: ["repository", "number", "edit_version"],
      optional: [],
    },
    {
      name: "moonhub_create_merge_request",
      description: "Create an MR without authorizing CI execution; draft is true or false (default).",
      permission: "write",
      required: ["repository", "title", "source", "target"],
      optional: ["description", "draft", "issue"],
    },
    {
      name: "moonhub_comment_merge_request",
      description: "Comment on an observed MR version; optional source coordinates and structured document identity start an inline discussion.",
      permission: "write",
      required: ["repository", "number", "version", "body"],
      optional: [
        "commit", "path", "side", "start_line", "end_line", "document_id", "file_id",
        "hunk_id", "diff_page", "mode", "ignore_comments", "ignore_tests",
      ],
    },
    {
      name: "moonhub_edit_merge_request",
      description: "Edit MR title, description or target branch using the last observed edit_version.",
      permission: "write",
      required: ["repository", "number", "edit_version"],
      optional: ["title", "description", "target"],
    },
    {
      name: "moonhub_reply_merge_discussion",
      description: "Reply to an MR discussion.",
      permission: "write",
      required: ["repository", "number", "discussion", "body"],
      optional: [],
    },
    {
      name: "moonhub_resolve_merge_discussion",
      description: "Resolve an MR discussion using its observed state_version.",
      permission: "write",
      required: ["repository", "number", "discussion", "state_version"],
      optional: [],
    },
    {
      name: "moonhub_reopen_merge_discussion",
      description: "Reopen an MR discussion using its observed state_version.",
      permission: "write",
      required: ["repository", "number", "discussion", "state_version"],
      optional: [],
    },
    {
      name: "moonhub_list_variables",
      description: "List readable repository configuration variables and their values. Values are not secrets.",
      permission: "read",
      required: ["repository"],
      optional: [],
    },
    {
      name: "moonhub_set_variable",
      description: "Save a nonsecret repository configuration variable using its observed version (0 creates). Requires repository owner/admin access; use secrets for credentials.",
      permission: "write",
      required: ["repository", "name", "value", "version"],
      optional: [],
    },
    {
      name: "moonhub_delete_variable",
      description: "Delete a repository configuration variable using its observed version. Requires repository owner/admin access.",
      permission: "write",
      required: ["repository", "name", "version"],
      optional: [],
    },
    {
      name: "moonhub_create_run",
      description: "Execute repository workflow code in CI. Requires explicit user intent to execute.",
      permission: "execute",
      required: ["repository", "branch", "workflow"],
      optional: ["inputs"],
    },
    {
      name: "moonhub_rerun_run",
      description: "Execute a CI run again. Requires explicit user intent to execute.",
      permission: "execute",
      required: ["repository", "number"],
      optional: [],
    },
    {
      name: "moonhub_cancel_run",
      description: "Cancel a CI run.",
      permission: "execute",
      required: ["repository", "number"],
      optional: [],
    },
    {
      name: "moonhub_approve_merge_checks",
      description: "Authorize workflow code execution for the explicitly observed MR version.",
      permission: "execute",
      required: ["repository", "number", "version"],
      optional: [],
    },
    {
      name: "moonhub_merge_merge_request",
      description: "Submit an MR merge for the explicitly observed version, subject to branch rules and checks. Requires explicit user intent to merge.",
      permission: "merge",
      required: ["repository", "number", "version"],
      optional: [],
    },
  ]
}

///|
fn string_arg(
  args : Map[String, Json],
  key : String,
  fallback? : String,
) -> String raise {
  match args.get(key) {
    Some(String(value)) => value
    None if fallback is Some(value) => value
    _ => raise @domain.BadRequest(message="String argument required: " + key)
  }
}

///|
fn decimal(value : String, zero~ : Bool = false) -> Int64 raise {
  guard !value.is_empty() &&
    value.length() <= 19 &&
    value.iter().all(ch => ch.is_ascii_digit()) &&
    (value == "0" || !value.has_prefix("0")) else {
    raise @domain.BadRequest(message="Canonical decimal string required")
  }
  let number = @string.parse_int64(value) catch {
    _ => raise @domain.BadRequest(message="Invalid decimal number")
  }
  guard number > 0L || (zero && number == 0L) else {
    raise @domain.BadRequest(message="Positive number required")
  }
  number
}

///|
fn tool_page(args : Map[String, Json]) -> Int64 raise {
  let page = decimal(string_arg(args, "page", fallback="1"))
  guard page <= 100000L else {
    raise @domain.BadRequest(message="Invalid page")
  }
  page
}

///|
fn tool_repo(args : Map[String, Json]) -> @domain.RepoId raise {
  guard string_arg(args, "repository").split_once("/") is Some((owner, name)) &&
    @domain.valid_repo_owner(owner.to_owned()) &&
    @domain.valid_repo_name(name.to_owned()) else {
    raise @domain.BadRequest(message="repository must be owner/name")
  }
  { owner: owner.to_owned(), name: name.to_owned(), }
}

///|
async fn markdown_arg(
  pool : @database.Database,
  root : String,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  args : Map[String, Json],
  key : String,
  fallback : String,
) -> String {
  @attachments.prepare_markdown(
    pool,
    root,
    scope,
    actor,
    string_arg(args, key, fallback~),
  )
}

///|
async fn invoke_tool(
  pool : @database.Database,
  root : String,
  coordinator : @pipeline.Coordinator,
  diff_executor : @gitops.DiffExecutor,
  actor : @domain.CurrentUser,
  name : String,
  args : Map[String, Json],
) -> Json {
  match name {
    "moonhub_get_user" =>
      return {
        "id": actor.id.to_string(),
        "username": actor.name_key,
        "display_name": actor.display_name,
      }
    "moonhub_list_repositories" =>
      return {
        "items": @repository.visible_repositories(pool, root, actor).map(repo => {
          repo.path()
        }),
      }
    "moonhub_list_inbox" => {
      let rows = @collaboration.inbox_items(
        pool,
        actor,
        string_arg(args, "filter", fallback="unread"),
        tool_page(args),
      )
      return {
        "unread": @collaboration.unread_notification_count(pool, actor).to_string(),
        "has_more": rows.length() > 50,
        "items": rows
        .iter()
        .take(50)
        .map(item => {
          (
            {
              "id": item.id.to_string(),
              "repository": item.repo.path(),
              "number": item.number.to_string(),
              "title": item.title,
              "kind": item.kind,
              "read": item.read,
              "url": item.url(),
            } : Json)
        })
        .collect(),
      }
    }
    "moonhub_mark_notification_read" =>
      return {
        "url": @collaboration.mark_notification_read(
          pool,
          actor,
          decimal(string_arg(args, "number")),
        ).url(),
      }
    _ => ()
  }
  let repo = tool_repo(args)
  let scope = @repository.repository_scope(pool, actor, repo)
  let id = if args.contains("number") {
    decimal(string_arg(args, "number"))
  } else {
    0L
  }
  match name {
    "moonhub_list_merge_requests" => {
      let status = string_arg(args, "status", fallback="open")
      guard ["open", "closed", "merged"].contains(status) else {
        raise @domain.BadRequest(message="Invalid MR status")
      }
      let rows = @collaboration.list_merge_requests(
        pool,
        scope,
        status,
        tool_page(args),
      )
      {
        "items": rows.iter().take(50).map(@user_api.mr_json).collect(),
        "has_more": rows.length() > 50,
      }
    }
    "moonhub_get_merge_request"
    | "moonhub_get_merge_request_checks"
    | "moonhub_get_merge_request_diff"
    | "moonhub_list_merge_discussions" => {
      let mr = @collaboration.require_merge_request(pool, scope, id)
      match name {
        "moonhub_get_merge_request_checks" =>
          {
            "version": mr.version.to_string(),
            "checks": @collaboration.merge_checks(pool, mr).map(
              @user_api.check_json,
            ),
          }
        "moonhub_get_merge_request_diff" => {
          let version = decimal(
            string_arg(args, "version", fallback=mr.version.to_string()),
          )
          let revision = @collaboration.merge_revision(pool, mr, version~)
          let dir = @repository.resolve_repository_dir(root, repo)
          let comparison = @gitops.revision_comparison(
            dir,
            revision,
            args.get("commit").map(_ => string_arg(args, "commit")),
          )
          let format = string_arg(args, "format", fallback="patch")
          guard format == "patch" || format == "structured" else {
            raise @domain.BadRequest(message="invalid diff format")
          }
          if format == "structured" {
            let page = tool_page(args)
            let result = diff_executor.structured(
              dir,
              comparison.base_sha,
              comparison.head_sha,
              @gitops.diff_options(
                mode=string_arg(args, "mode", fallback="lexical"),
                ignore_comments=string_arg(
                  args,
                  "ignore_comments",
                  fallback="true",
                ),
                ignore_tests=string_arg(args, "ignore_tests", fallback="true"),
              ),
              page=page.to_int(),
              file_id=string_arg(args, "file_id", fallback=""),
            )
            @repository.authorize_repository(pool, actor, repo, Read)
            if result is Object(fields) {
              fields.set("version", Json(version.to_string()))
            }
            return result
          }
          let patch = @gitops.merge_git(dir, [
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
          @repository.authorize_repository(pool, actor, repo, Read)
          {
            "version": version.to_string(),
            "target": revision.target_branch,
            "base_sha": comparison.base_sha,
            "head_sha": comparison.head_sha,
            "patch": patch,
          }
        }
        "moonhub_list_merge_discussions" => {
          let page = tool_page(args)
          match args.get("discussion") {
            Some(_) => {
              let discussion = @collaboration.merge_discussion(
                pool,
                scope,
                actor,
                mr,
                decimal(string_arg(args, "discussion")),
                page~,
              )
              {
                "discussion": @user_api.discussion_json(discussion),
                "has_more": page * 50L < discussion.reply_count,
              }
            }
            None => {
              let rows = @collaboration.list_merge_discussions(
                pool,
                scope,
                actor,
                mr,
                page,
                filter=string_arg(args, "filter", fallback="all"),
              )
              {
                "items": rows
                .iter()
                .take(50)
                .map(d => @user_api.discussion_json(d, preview=true))
                .collect(),
                "has_more": rows.length() > 50,
              }
            }
          }
        }
        _ => {
          let rows = @collaboration.list_merge_activity(
            pool,
            mr,
            tool_page(args),
          )
          {
            "mr": @user_api.mr_json(mr),
            "activity": rows
            .iter()
            .take(50)
            .map(a => @user_api.activity_json(a))
            .collect(),
            "has_more": rows.length() > 50,
            "checks": @collaboration.merge_checks(pool, mr).map(
              @user_api.check_json,
            ),
          }
        }
      }
    }
    "moonhub_list_issues" => {
      let status = string_arg(args, "status", fallback="open")
      guard ["open", "closed"].contains(status) else {
        raise @domain.BadRequest(message="Invalid issue status")
      }
      let assigned = string_arg(args, "assigned", fallback="")
      guard ["", "me"].contains(assigned) else {
        raise @domain.BadRequest(message="assigned must be me")
      }
      let rows = @collaboration.list_issues(
        pool,
        scope,
        status,
        tool_page(args),
        assigned == "me",
        actor.id,
        string_arg(args, "q", fallback=""),
      )
      {
        "items": rows.iter().take(50).map(@user_api.issue_json).collect(),
        "has_more": rows.length() > 50,
      }
    }
    "moonhub_get_issue" => {
      let issue = @collaboration.require_issue(pool, scope, id)
      let rows = @collaboration.list_issue_activity(
        pool,
        issue,
        tool_page(args),
      )
      {
        "issue": @user_api.issue_json(issue),
        "has_more": rows.length() > 50,
        "activity": rows
        .iter()
        .take(50)
        .map(a => {
          (
            {
              "actor": a.actor,
              "kind": a.kind,
              "body": a.body,
              "created_at": a.created_at,
            } : Json)
        })
        .collect(),
      }
    }
    "moonhub_create_issue" => {
      let created = @collaboration.create_issue(
        pool,
        scope,
        actor,
        string_arg(args, "title"),
        markdown_arg(pool, root, scope, actor, args, "description", ""),
        decimal(string_arg(args, "assignee", fallback="0"), zero=true),
      )
      @user_api.issue_json(@collaboration.require_issue(pool, scope, created))
    }
    "moonhub_comment_issue"
    | "moonhub_edit_issue"
    | "moonhub_close_issue"
    | "moonhub_reopen_issue" => {
      let issue = @collaboration.require_issue(pool, scope, id)
      let action = match name {
        "moonhub_comment_issue" => "comment"
        "moonhub_edit_issue" => "edit"
        "moonhub_close_issue" => "close"
        _ => "reopen"
      }
      @collaboration.mutate_issue(
        pool,
        scope,
        actor,
        issue,
        if action == "comment" {
          issue.edit_version
        } else {
          decimal(string_arg(args, "edit_version"))
        },
        action,
        string_arg(args, "title", fallback=issue.title),
        markdown_arg(
          pool,
          root,
          scope,
          actor,
          args,
          "description",
          issue.description,
        ),
        decimal(
          string_arg(args, "assignee", fallback=issue.assignee_id.to_string()),
          zero=true,
        ),
        markdown_arg(pool, root, scope, actor, args, "body", ""),
      )
      @user_api.issue_json(@collaboration.require_issue(pool, scope, id))
    }
    "moonhub_create_merge_request" => {
      let draft = string_arg(args, "draft", fallback="false")
      guard ["true", "false"].contains(draft) else {
        raise @domain.BadRequest(message="draft must be true or false")
      }
      let description = markdown_arg(
        pool, root, scope, actor, args, "description", "",
      )
      @repository.with_repository_write(pool, root, actor, repo, (scope, dir) => {
        @user_api.mr_json(
          @collaboration.create_merge_request(
            pool,
            scope,
            dir,
            actor,
            string_arg(args, "title"),
            description,
            string_arg(args, "source"),
            string_arg(args, "target"),
            draft == "true",
            issue=decimal(string_arg(args, "issue", fallback="0"), zero=true),
            authorize_checks=false,
          ),
        )
      })
    }
    "moonhub_comment_merge_request"
    | "moonhub_edit_merge_request"
    | "moonhub_reply_merge_discussion"
    | "moonhub_resolve_merge_discussion"
    | "moonhub_reopen_merge_discussion"
    | "moonhub_approve_merge_checks"
    | "moonhub_merge_merge_request" => {
      let prepared = if name == "moonhub_comment_merge_request" &&
        args.contains("path") {
        let mr = @collaboration.require_merge_request(pool, scope, id)
        let fields : Map[String, String] = Map([])
        for
          key in [
            "document_id", "file_id", "hunk_id", "diff_page", "mode", "ignore_comments",
            "ignore_tests",
          ] {
          if args.contains(key) {
            fields.set(key, string_arg(args, key))
          }
        }
        Some(
          @collaboration.prepare_anchored_merge_discussion(
            pool,
            scope,
            actor,
            mr,
            @repository.resolve_repository_dir(root, repo),
            decimal(string_arg(args, "version")),
            args
            .get("commit")
            .map(_ => string_arg(args, "commit"))
            .filter(s => !s.is_empty()),
            string_arg(args, "path"),
            string_arg(args, "side"),
            decimal(string_arg(args, "start_line")),
            decimal(
              string_arg(
                args,
                "end_line",
                fallback=string_arg(args, "start_line"),
              ),
            ),
            markdown_arg(pool, root, scope, actor, args, "body", ""),
            structured?=@web_context.diff_selection(fields).map(selection => {
              (diff_executor, selection)
            }),
          ),
        )
      } else {
        None
      }
      @repository.with_repository_write(pool, root, actor, repo, (scope, dir) => {
        let mr = @collaboration.require_merge_request(pool, scope, id)
        let mr = if [
            "moonhub_approve_merge_checks", "moonhub_merge_merge_request",
          ].contains(name) {
          @collaboration.refresh_merge_request(pool, scope, dir, mr)
        } else {
          mr
        }
        match name {
          "moonhub_comment_merge_request" =>
            if prepared is Some(prepared) {
              ignore(
                @collaboration.create_prepared_merge_discussion(
                  pool, scope, actor, mr, prepared,
                ),
              )
            } else {
              @collaboration.submit_merge_review(
                pool,
                actor,
                mr,
                decimal(string_arg(args, "version")),
                "comment",
                markdown_arg(pool, root, scope, actor, args, "body", ""),
              )
            }
          "moonhub_edit_merge_request" => {
            guard args.contains("title") ||
              args.contains("description") ||
              args.contains("target") else {
              raise @domain.BadRequest(
                message="MR edit requires title, description or target",
              )
            }
            @collaboration.update_merge_request(
              pool,
              scope,
              dir,
              actor,
              mr,
              string_arg(args, "title", fallback=mr.title),
              markdown_arg(
                pool,
                root,
                scope,
                actor,
                args,
                "description",
                mr.description,
              ),
              string_arg(args, "target", fallback=mr.target),
              decimal(string_arg(args, "edit_version")),
            )
          }
          "moonhub_reply_merge_discussion" =>
            ignore(
              @collaboration.reply_merge_discussion(
                pool,
                scope,
                actor,
                mr,
                decimal(string_arg(args, "discussion")),
                markdown_arg(pool, root, scope, actor, args, "body", ""),
              ),
            )
          "moonhub_resolve_merge_discussion"
          | "moonhub_reopen_merge_discussion" =>
            @collaboration.set_merge_discussion_resolved(
              pool,
              scope,
              actor,
              mr,
              decimal(string_arg(args, "discussion")),
              decimal(string_arg(args, "state_version")),
              name == "moonhub_resolve_merge_discussion",
            )
          "moonhub_approve_merge_checks" =>
            @collaboration.approve_merge_checks(
              pool,
              scope,
              actor,
              mr,
              decimal(string_arg(args, "version")),
            )
          _ =>
            @collaboration.enqueue_merge(
              pool,
              scope,
              actor,
              mr,
              decimal(string_arg(args, "version")),
            )
        }
        @user_api.mr_json(@collaboration.require_merge_request(pool, scope, id))
      })
    }
    "moonhub_list_variables" =>
      {
        "items": @pipeline.list_variables(pool, actor, repo).map(
          @user_api.variable_json,
        ),
      }
    "moonhub_set_variable" => {
      let name = string_arg(args, "name").to_upper()
      @pipeline.save_variable(
        pool,
        actor,
        repo,
        name,
        string_arg(args, "value"),
        decimal(string_arg(args, "version"), zero=true),
      )
      let variable = @pipeline.list_variables(pool, actor, repo)
        .iter()
        .find_first(variable => variable.name == name)
      guard variable is Some(variable) else {
        raise @domain.NotFound(message="Variable changed. Reload its value.")
      }
      @user_api.variable_json(variable)
    }
    "moonhub_delete_variable" => {
      @pipeline.delete_variable(
        pool,
        actor,
        repo,
        string_arg(args, "name"),
        decimal(string_arg(args, "version")),
      )
      { "ok": true }
    }
    "moonhub_list_runs" =>
      {
        "items": @pipeline.list_runs(pool, actor, repo)
        .iter()
        .take(50)
        .map(@user_api.run_json)
        .collect(),
      }
    "moonhub_get_run" =>
      {
        "run": @user_api.run_json(@pipeline.get_run(pool, actor, repo, id)),
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
              "conclusion": @user_api.conclusion_json(job.conclusion),
              "attempt": job.attempt_id.map(id => id.to_string()).unwrap_or(""),
            } : Json)
        }),
      }
    "moonhub_get_run_logs" => {
      let logs = coordinator.read_log_page(
        actor,
        repo,
        id,
        decimal(string_arg(args, "attempt")),
        after=decimal(string_arg(args, "after", fallback="0"), zero=true),
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
    }
    "moonhub_create_run" =>
      @user_api.run_json(
        @pipeline.create_run(
          pool,
          root,
          actor,
          repo,
          string_arg(args, "branch"),
          string_arg(args, "workflow"),
          inputs=match args.get("inputs") {
            None => Map([])
            Some(Object(values)) => values
            _ =>
              raise @domain.BadRequest(message="inputs must be a JSON object")
          },
        ),
      )
    "moonhub_rerun_run" =>
      @user_api.run_json(@pipeline.rerun_run(pool, root, actor, repo, id))
    "moonhub_cancel_run" => {
      coordinator.cancel_run(actor, repo, id)
      @user_api.run_json(@pipeline.get_run(pool, actor, repo, id))
    }
    _ => raise @domain.BadRequest(message="Unsupported tool")
  }
}
