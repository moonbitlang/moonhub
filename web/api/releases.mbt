///|
fn release_token(req : @moonback.Request) -> String? raise {
  guard req.headers.get("sec-fetch-site") != Some("cross-site") else {
    raise @domain.Forbidden(message="cross-site request rejected")
  }
  let headers = req.headers.get_all("authorization")
  if headers.is_empty() {
    return None
  }
  guard headers.length() == 1 &&
    headers[0].split_once(" ") is Some((scheme, token)) &&
    ["bearer", "token"].contains(scheme.to_lower().to_owned()) &&
    token.length() <= 80 else {
    raise @domain.Unauthorized(message="release credential required")
  }
  Some(token.to_owned())
}

///|
fn release_access(
  pool : @database.Database,
  coordinator : @pipeline.Coordinator,
  req : @moonback.Request,
  repo : @domain.RepoId,
) -> @releases.Access raise {
  let token = release_token(req)
  let authenticate : (Bool) -> @domain.CurrentUser raise = write => {
    guard token is Some(token) else {
      raise @domain.Unauthorized(message="release credential required")
    }
    @identity.authenticate_access_token(
      pool,
      token,
      if write {
        "write"
      } else {
        "read"
      },
    ) catch {
      @domain.Unauthorized(_) =>
        coordinator.authenticate_job_api(
          token,
          repo,
          if write {
            "contents:write"
          } else {
            "contents:read"
          },
        )
      err => raise err
    }
  }
  let actor = match token {
    None => None
    Some(_) => Some(authenticate(false))
  }
  @releases.access(repo, actor, recheck=write => {
    if token is Some(_) || write {
      ignore(authenticate(write))
    }
  })
}

///|
fn release_base(origin : String, repo : @domain.RepoId) -> String raise {
  guard !origin.is_empty() else {
    raise @domain.BadRequest(message="release public origin is not configured")
  }
  origin + "/api/v3/repos/" + repo.path()
}

///|
fn release_asset_json(
  origin : String,
  repo : @domain.RepoId,
  asset : @releases.Asset,
) -> Json raise {
  let base = release_base(origin, repo)
  {
    "id": asset.id.to_double(),
    "node_id": "RA_" + asset.id.to_string(),
    "name": asset.name,
    "label": asset.label,
    "size": asset.size.to_double(),
    "digest": asset.digest,
    "state": "uploaded",
    "content_type": asset.media_type,
    "created_at": asset.created_at,
    "updated_at": asset.created_at,
    "download_count": 0,
    "url": base + "/releases/assets/" + asset.id.to_string(),
    "browser_download_url": base +
    "/release-assets/" +
    asset.id.to_string() +
    "/download",
  }
}

///|
fn release_json(
  origin : String,
  repo : @domain.RepoId,
  release : @releases.Release,
) -> Json raise {
  let base = release_base(origin, repo) + "/releases/" + release.id.to_string()
  {
    "id": release.id.to_double(),
    "node_id": "R_" + release.id.to_string(),
    "tag_name": release.tag,
    "target_commitish": release.commit_sha,
    "name": release.title,
    "body": release.body,
    "draft": release.draft,
    "prerelease": release.prerelease,
    "immutable": !release.draft,
    "created_at": release.created_at,
    "published_at": release.published_at
    .map(Json::string)
    .unwrap_or(Json::null()),
    "author": { "login": release.author, "node_id": "U_" + release.author },
    "url": base,
    "html_url": origin +
    "/" +
    repo.path() +
    "/releases/" +
    release.id.to_string(),
    "upload_url": base + "/assets{?name,label}",
    "assets": release.assets.map(a => release_asset_json(origin, repo, a)),
  }
}

///|
fn release_handler(
  handler : async (@moonback.Request, @moonback.Responder) -> Unit,
) -> @moonback.Handler {
  (req, res) => {
    handler(req, res) catch {
      err => {
        let (status, message) = match err {
          @domain.Unauthorized(message~) => (401, message)
          @domain.Forbidden(message~) => (403, message)
          @domain.NotFound(message~) => (404, message)
          @domain.BadRequest(message~) => (422, message)
          @releases.Conflict(message) => (409, message)
          _ => (500, @domain.internal_error_message)
        }
        res.send_json({ "message": message }, status~, headers={
          "Cache-Control": "no-store",
          "Connection": "close",
        })
      }
    }
  }
}

///|
fn release_id(req : @moonback.Request) -> Int64 raise {
  @web_context.positive_resource_number(
    @web_context.required_param(req, "id", "release"),
  )
}

///|
pub let releases_api_module : @moonback.Module = Module(ctx => {
  let service = ctx.require(@web_context.release_service_key)
  let origin = ctx.require(@web_context.release_origin_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  let transfers = @async.Semaphore(2)
  ctx.get(
    "/repos/:owner/:repo/schedules",
    api_handler(req => {
      let (enabled, error) = @pipeline.scheduled_runs_status(
        pool,
        api_actor(pool, req, "read"),
        @web_context.repo_param(req),
      )
      { "enabled": enabled, "last_error": error }
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/schedules",
    api_handler(req => {
      let actor = api_actor(pool, req, "execute")
      let body = api_body(req, ["enabled"])
      @pipeline.set_scheduled_runs(
        pool,
        actor,
        @web_context.repo_param(req),
        release_bool(body, "enabled", false),
      )
      { "ok": true }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/actions/workflows/:workflow/runs",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      let actor = match release_token(req) {
        None => raise @domain.Unauthorized(message="actions: read required")
        Some(token) =>
          @identity.authenticate_access_token(pool, token, "read") catch {
            @domain.Unauthorized(_) =>
              coordinator.authenticate_job_api(token, repo, "actions:read")
            err => raise err
          }
      }
      let path = ".github/workflows/" +
        @web_context.required_param(req, "workflow", "workflow")
      let (count, runs) = @pipeline.workflow_run_history(
        pool,
        actor,
        repo,
        path,
        page=number(req.query().get("page").unwrap_or("1")),
        per_page=number(req.query().get("per_page").unwrap_or("30")),
        status=req.query().get("status").unwrap_or(""),
        branch=req.query().get("branch").unwrap_or(""),
      )
      res.send_json(
        {
          "total_count": count.to_double(),
          "workflow_runs": runs.map(run => {
            (
              {
                "id": run.id.to_double(),
                "name": run.workflow_name,
                "display_title": run.display_title,
                "head_sha": run.commit_sha,
                "head_branch": run.source_branch,
                "status": if run.state is @pipeline.Completed {
                  "completed"
                } else if run.state is @pipeline.Running {
                  "in_progress"
                } else {
                  "queued"
                },
                "conclusion": run.conclusion
                .map(c => {
                  match c {
                    @pipeline.Success => "success"
                    @pipeline.Failure => "failure"
                    @pipeline.Cancelled => "cancelled"
                    @pipeline.TimedOut => "timed_out"
                    @pipeline.Lost => "lost"
                    @pipeline.Skipped => "skipped"
                  }
                })
                .map(Json::string)
                .unwrap_or(Json::null()),
              } : Json)
          }),
        },
        headers={ "Cache-Control": "no-store" },
      )
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/releases",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      ignore(release_base(origin, repo))
      let access = release_access(pool, coordinator, req, repo)
      let page = number(req.query().get("page").unwrap_or("1")).to_int()
      let per_page = number(req.query().get("per_page").unwrap_or("30")).to_int()
      let releases = service.list(access, page~, per_page~)
      let headers = { "Cache-Control": "no-store" }
      if releases.length() == per_page {
        headers["Link"] = "<" +
          release_base(origin, repo) +
          "/releases?page=" +
          (page + 1).to_string() +
          "&per_page=" +
          per_page.to_string() +
          ">; rel=\"next\""
      }
      res.send_json(
        ToJson::to_json(releases.map(r => release_json(origin, repo, r))),
        headers~,
      )
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/releases/latest",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      ignore(release_base(origin, repo))
      res.send_json(
        release_json(
          origin,
          repo,
          service.latest(release_access(pool, coordinator, req, repo)),
        ),
        headers={ "Cache-Control": "no-store" },
      )
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/releases/tags/:tag",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      ignore(release_base(origin, repo))
      res.send_json(
        release_json(
          origin,
          repo,
          service.by_tag(
            release_access(pool, coordinator, req, repo),
            @web_context.required_param(req, "tag", "tag"),
          ),
        ),
        headers={ "Cache-Control": "no-store" },
      )
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/releases",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      ignore(release_base(origin, repo))
      let access = release_access(pool, coordinator, req, repo)
      let body = api_body(req, [
        "tag_name", "target_commitish", "name", "body", "draft", "prerelease", "make_latest",
      ])
      let tag = field(body, "tag_name")
      let r = service.create(
        access,
        tag,
        field(body, "target_commitish", fallback="HEAD"),
        field(body, "name", fallback=tag),
        field(body, "body", fallback=""),
        draft=release_bool(body, "draft", false),
        prerelease=release_bool(body, "prerelease", false),
        latest=body.get("make_latest") != Some(Json::string("false")),
      )
      res.send_json(release_json(origin, repo, r), status=201, headers={
        "Cache-Control": "no-store",
      })
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/releases/:id",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      ignore(release_base(origin, repo))
      res.send_json(
        release_json(
          origin,
          repo,
          service.get(
            release_access(pool, coordinator, req, repo),
            release_id(req),
          ),
        ),
        headers={ "Cache-Control": "no-store" },
      )
    }),
  )
  ctx.add_route(
    Patch,
    "/repos/:owner/:repo/releases/:id",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      ignore(release_base(origin, repo))
      let access = release_access(pool, coordinator, req, repo)
      let body = api_body(req, [
        "tag_name", "name", "body", "target_commitish", "draft", "prerelease", "make_latest",
      ])
      if body.contains("tag_name") {
        guard field(body, "tag_name") ==
          service.get(access, release_id(req)).tag else {
          raise @domain.BadRequest(message="release tag cannot be changed")
        }
      }
      let string_value : (String) -> String? raise = key => {
        match body.get(key) {
          None => None
          Some(String(s)) => Some(s)
          _ => raise @domain.BadRequest(message="string required")
        }
      }
      let bool_value : (String) -> Bool? raise = key => {
        match body.get(key) {
          None => None
          Some(True) => Some(true)
          Some(False) => Some(false)
          _ => raise @domain.BadRequest(message="boolean required")
        }
      }
      let title = string_value("name")
      let notes = string_value("body")
      let target = string_value("target_commitish")
      let draft = bool_value("draft")
      let prerelease = bool_value("prerelease")
      res.send_json(
        release_json(
          origin,
          repo,
          service.edit(
            access,
            release_id(req),
            title?,
            body?=notes,
            target?,
            draft?,
            prerelease?,
            latest=body.get("make_latest") == Some(Json::string("true")),
          ),
        ),
        headers={ "Cache-Control": "no-store" },
      )
    }),
  )
  ctx.add_route(
    Delete,
    "/repos/:owner/:repo/releases/:id",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      ignore(release_base(origin, repo))
      service.delete(
        release_access(pool, coordinator, req, repo),
        release_id(req),
      )
      res.respond(status=204).write(b"")
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/releases/:id/assets",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      ignore(release_base(origin, repo))
      let access = release_access(pool, coordinator, req, repo)
      let reader = req.body.reader(no_buffer=true)
      @async.with_timeout(30000, () => transfers.acquire())
      defer transfers.release()
      let a = service.upload(
        access,
        release_id(req),
        req.query().get("name").unwrap_or(""),
        req.query().get("label").unwrap_or(""),
        req.headers
        .get("content-type")
        .map(v => v.to_owned())
        .unwrap_or("application/octet-stream"),
        () => reader.read_some(max_len=65536),
      )
      res.send_json(release_asset_json(origin, repo, a), status=201, headers={
        "Cache-Control": "no-store",
      })
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/releases/assets/:id",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      ignore(release_base(origin, repo))
      let access = release_access(pool, coordinator, req, repo)
      if req.headers
        .get("accept")
        .unwrap_or("")
        .contains("application/octet-stream") {
        @async.with_timeout(30000, () => transfers.acquire())
        defer transfers.release()
        service.download(access, release_id(req), (a, reader, authorize) => {
          let writer = res.respond(headers={
            "Content-Type": "application/octet-stream",
            "Content-Length": a.size.to_string(),
            "Content-Disposition": @web_context.attachment_disposition(
              a.name,
              inline=false,
            ),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
          })
          while @async.with_timeout(30000, () => reader.read()) is Some(bytes) {
            authorize()
            @async.with_timeout(30000, () => writer.write(bytes))
          }
        })
      } else {
        res.send_json(
          release_asset_json(
            origin,
            repo,
            service.get_asset(access, release_id(req)),
          ),
          headers={ "Cache-Control": "no-store" },
        )
      }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/release-assets/:id/download",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      ignore(release_base(origin, repo))
      let access = release_access(pool, coordinator, req, repo)
      @async.with_timeout(30000, () => transfers.acquire())
      defer transfers.release()
      service.download(access, release_id(req), (a, reader, authorize) => {
        let writer = res.respond(headers={
          "Content-Type": "application/octet-stream",
          "Content-Length": a.size.to_string(),
          "Content-Disposition": @web_context.attachment_disposition(
            a.name,
            inline=false,
          ),
          "Cache-Control": "no-store",
          "X-Content-Type-Options": "nosniff",
        })
        while @async.with_timeout(30000, () => reader.read()) is Some(bytes) {
          authorize()
          @async.with_timeout(30000, () => writer.write(bytes))
        }
      })
    }),
  )
  ctx.add_route(
    Delete,
    "/repos/:owner/:repo/releases/assets/:id",
    release_handler((req, res) => {
      let repo = @web_context.repo_param(req)
      ignore(release_base(origin, repo))
      service.delete_asset(
        release_access(pool, coordinator, req, repo),
        release_id(req),
      )
      res.respond(status=204).write(b"")
    }),
  )
})

///|
pub let release_graphql_module : @moonback.Module = Module(ctx => {
  let service = ctx.require(@web_context.release_service_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  ctx.post(
    "/",
    release_handler((req, res) => {
      let body = api_body(req, ["query", "variables", "operationName"])
      let query = field(body, "query")
      guard query.has_prefix("query RepositoryReleaseByTag(") &&
        body.get("variables") is Some(Object(variables)) else {
        raise @domain.BadRequest(message="unsupported GraphQL operation")
      }
      let repo : @domain.RepoId = {
        owner: field(variables, "owner"),
        name: field(variables, "name"),
      }
      let access = release_access(pool, coordinator, req, repo)
      let result = try {
        let r = service.by_tag(access, field(variables, "tagName"))
        ({ "databaseId": r.id.to_double(), "isDraft": r.draft } : Json)
      } catch {
        @domain.NotFound(_) => Json::null()
        err => raise err
      }
      res.send_json({ "data": { "repository": { "release": result } } }, headers={
        "Cache-Control": "no-store",
      })
    }),
  )
})

///|
fn release_bool(
  fields : Map[String, Json],
  key : String,
  fallback : Bool,
) -> Bool raise {
  match fields.get(key) {
    None => fallback
    Some(True) => true
    Some(False) => false
    _ => raise @domain.BadRequest(message="boolean field required: " + key)
  }
}
