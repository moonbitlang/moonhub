///|
fn issue_assignee_value(form : Map[String, String]) -> Int64 raise {
  let value = form.get("assignee").unwrap_or("0")
  if value == "0" {
    0L
  } else {
    merge_number(value)
  }
}

///|
fn issues_module(assets : Map[String, String]) -> @moonback.Module {
  Module(ctx => {
    let pool = db_pool(ctx)
    let addresses = ctx
      .config()
      .get_custom(config_ssh_addresses)
      .unwrap_or(no_ssh_address_config)
    ctx.get("/:owner/:repo/issues", async fn(req, res) {
      let actor = require_current_user(req)
      let scope = repository_scope(pool, actor, req.repo_param())
      let status = req.query().get("status").unwrap_or("open")
      guard status == "open" || status == "closed" else {
        raise BadRequest(message="invalid issue status")
      }
      let page = match req.query().get("page") {
        Some(value) => merge_number(value)
        None => 1L
      }
      guard page <= 100000L else { raise BadRequest(message="invalid page") }
      let mine = req.query().get("assigned") == Some("me")
      let query = req.query().get("q").unwrap_or("").trim().to_owned()
      guard query.length() <= 200 else {
        raise BadRequest(message="search query is too long")
      }
      let issues = pool.with_client(client => {
        client
        .query_all(
          "\{issue_select} WHERE i.repository_id = ? AND i.status = ? AND (? = 0 OR i.assignee_id = ?) AND (? = '' OR instr(lower(i.title), lower(?)) > 0) ORDER BY i.number DESC LIMIT 51 OFFSET ?",
          params=[
            scope.id,
            status,
            mine,
            actor.id,
            query,
            query,
            (page - 1L) * 50L,
          ],
        )
        .map(Issue::from_row)
      })
      let clone = effective_ssh_endpoint(pool, addresses).map(endpoint => {
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
          can_access_repository(pool, actor, scope.repo, Write),
          clone,
          manager=can_manage_team(pool, actor, scope.team_id),
        ),
        headers=private_page_headers(),
      )
    })
    ctx.get("/:owner/:repo/issues/new", async fn(req, res) {
      let actor = require_current_user(req)
      let scope = repository_scope(pool, actor, req.repo_param())
      authorize_repository(pool, actor, scope.repo, Write)
      res.send_html(
        render_issue_form(
          assets,
          actor,
          scope,
          None,
          manager=can_manage_team(pool, actor, scope.team_id),
          issue_assignees(pool, scope),
          request_form_token(req, "issues"),
          Map([]),
          None,
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/:owner/:repo/issues", async fn(req, res) {
      let actor = require_current_user(req)
      let scope = repository_scope(pool, actor, req.repo_param())
      authorize_repository(pool, actor, scope.repo, Write)
      let form = protected_form(req, "issues")
      let number = create_issue(
        pool,
        scope,
        actor,
        form.get("title").unwrap_or(""),
        form.get("description").unwrap_or(""),
        issue_assignee_value(form),
      ) catch {
        BadRequest(message~) => {
          res.send_html(
            render_issue_form(
              assets,
              actor,
              scope,
              None,
              issue_assignees(pool, scope),
              request_form_token(req, "issues"),
              form,
              Some(message),
              manager=can_manage_team(pool, actor, scope.team_id),
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
          location="\{repo_link(scope.repo)}/issues/\{number}",
        ),
      )
    })
    ctx.get("/:owner/:repo/issues/:number", async fn(req, res) {
      let actor = require_current_user(req)
      let scope = repository_scope(pool, actor, req.repo_param())
      let issue = require_issue(
        pool,
        scope,
        merge_number(req.required_param("number", "issue")),
      )
      let page = match req.query().get("page") {
        Some(value) => merge_number(value)
        None => 1L
      }
      guard page <= 100000L else { raise BadRequest(message="invalid page") }
      let activity = pool.with_client(client => {
        client.query_all(
          "SELECT a.*, u.display_name AS actor FROM issue_activity AS a JOIN \"user\" AS u ON u.id = a.actor_id WHERE a.issue_id = ? ORDER BY a.id DESC LIMIT 51 OFFSET ?",
          params=[issue.id, (page - 1L) * 50L],
        )
      })
      let related = pool.with_client(client => {
        client
        .query_all(
          "\{merge_request_select} WHERE m.repository_id = ? AND m.issue_id = ? ORDER BY m.number DESC LIMIT 50",
          params=[scope.id, issue.id],
        )
        .map(MergeRequest::from_row)
      })
      let clone = effective_ssh_endpoint(pool, addresses).map(endpoint => {
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
          can_access_repository(pool, actor, scope.repo, Write),
          can_manage_team(pool, actor, scope.team_id),
          request_form_token(req, "issues"),
          clone,
        ),
        headers=private_page_headers(),
      )
    })
    ctx.get("/:owner/:repo/issues/:number/edit", async fn(req, res) {
      let actor = require_current_user(req)
      let scope = repository_scope(pool, actor, req.repo_param())
      authorize_repository(pool, actor, scope.repo, Write)
      let issue = require_issue(
        pool,
        scope,
        merge_number(req.required_param("number", "issue")),
      )
      guard issue.author_id == actor.id ||
        can_manage_team(pool, actor, scope.team_id) else {
        raise Forbidden(
          message="only the author or a team administrator may edit this issue",
        )
      }
      res.send_html(
        render_issue_form(
          assets,
          actor,
          scope,
          Some(issue),
          issue_assignees(pool, scope),
          request_form_token(req, "issues"),
          Map([]),
          None,
          manager=can_manage_team(pool, actor, scope.team_id),
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/:owner/:repo/issues/:number/:action", async fn(req, res) {
      let actor = require_current_user(req)
      let scope = repository_scope(pool, actor, req.repo_param())
      let form = protected_form(req, "issues")
      let issue = require_issue(
        pool,
        scope,
        merge_number(req.required_param("number", "issue")),
      )
      let action = req.required_param("action", "action")
      let expected = if action == "comment" {
        issue.edit_version
      } else {
        merge_number(form.get("edit_version").unwrap_or(""))
      }
      mutate_issue(
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
        BadRequest(message~) if action == "edit" => {
          res.send_html(
            render_issue_form(
              assets,
              actor,
              scope,
              Some(issue),
              issue_assignees(pool, scope),
              request_form_token(req, "issues"),
              form,
              Some(message),
              manager=can_manage_team(pool, actor, scope.team_id),
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
          location="\{repo_link(scope.repo)}/issues/\{issue.number}",
        ),
      )
    })
  })
}
