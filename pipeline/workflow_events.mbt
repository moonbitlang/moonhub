///|
pub async fn dispatch_repository_event(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  event_type : String,
  payload : Map[String, Json],
  request_id~ : String = "",
) -> Int64 {
  let scope = @runtime.require_run_author(pool, actor, repo)
  guard !event_type.is_empty() &&
    event_type.length() <= 100 &&
    !event_type.contains("\u0000") &&
    payload.length() <= 10 &&
    @utf8.encode(ToJson::to_json(payload).stringify()).length() <= 65535 else {
    raise @domain.BadRequest(
      message="repository dispatch requires an event type and at most 10 payload fields / 65535 bytes",
    )
  }
  guard request_id.length() <= 100 &&
    request_id
    .iter()
    .all(c => {
      c.is_ascii_alphabetic() || c.is_ascii_digit() || ['_', '-'].contains(c)
    }) else {
    raise @domain.BadRequest(message="invalid dispatch request ID")
  }
  let key = "dispatch:" +
    (if request_id.is_empty() { @identity.random_hex(16) } else { request_id })
  @repository.with_repository_write(pool, root, actor, scope, (scope, dir) => {
    ignore(@runtime.require_run_author(pool, actor, repo))
    let existing = pool.with_client(c => {
      c.query_opt(
        "SELECT id,payload_json FROM pipeline_workflow_event WHERE repository_id=? AND source_key=?",
        params=[scope.id, key],
      )
    })
    if existing is Some(existing) {
      let saved = @json.parse((existing.get_name("payload_json") : String))
      guard saved
        is { "action": String(action), "client_payload": Object(values), .. } &&
        action == event_type &&
        values == payload else {
        raise @runtime.Conflict(
          "dispatch request ID already has another payload",
        )
      }
      return existing.get_name("id")
    }
    let branch : String = pool.with_client(c => {
      c
      .query_one("SELECT default_branch FROM repository WHERE id=?", params=[
        scope.id,
      ])
      .get_name("default_branch")
    })
    let sha = @gitops.branch_sha(dir, branch)
    let pin = "refs/moonhub/dispatch/" + @identity.hash_token(key)
    let mut committed = false
    ignore(@gitops.merge_git(dir, ["update-ref", "--no-deref", pin, sha]))
    defer (if !committed {
      @async.protect_from_cancel(() => {
        ignore(
          @gitops.merge_git(dir, ["update-ref", "--no-deref", "-d", pin, sha]),
        )
      }) catch {
        _ => println("dispatch snapshot cleanup failed")
      }
    })
    ignore(@runtime.require_run_author(pool, actor, repo))
    let event : Json = {
      "action": event_type,
      "client_payload": ToJson::to_json(payload),
      "repository": { "full_name": repo.owner + "/" + repo.name },
      "ref": "refs/heads/" + branch,
    }
    let id : Int64 = pool.with_client(c => {
      c
      .query_one(
        "INSERT INTO pipeline_workflow_event(repository_id,actor_id,source_key,event_name,branch,commit_sha,payload_json) VALUES(?,?,?,'repository_dispatch',?,?,?) RETURNING id",
        params=[scope.id, actor.id, key, branch, sha, event.stringify()],
      )
      .get_name("id")
    })
    committed = true
    id
  })
}

///|
pub async fn run_next_workflow_event(
  pool : @database.Database,
  root : String,
) -> Bool {
  let selected = pool.with_client(c => {
    c.query_opt(
      "SELECT e.*,t.name_key AS owner,r.name AS repo,u.name_key AS actor FROM pipeline_workflow_event e JOIN repository r ON r.id=e.repository_id JOIN team t ON t.id=r.team_id JOIN user u ON u.id=e.actor_id WHERE e.state='pending' AND e.retry_after<=CAST(strftime('%s','now') AS INTEGER) ORDER BY e.id LIMIT 1",
    )
  })
  guard selected is Some(selected) else { return false }
  let id : Int64 = selected.get_name("id")
  let repo : @domain.RepoId = {
    owner: selected.get_name("owner"),
    name: selected.get_name("repo"),
  }
  errdefer (pool.with_client(c => {
    ignore(
      c.execute(
        "UPDATE pipeline_workflow_event SET retry_after=CAST(strftime('%s','now') AS INTEGER)+30,last_error='Event processing interrupted; retrying.' WHERE id=? AND state='pending'",
        params=[id],
      ),
    )
  }) catch {
    _ => ()
  })
  let mut diagnostic = ""
  try {
    let actor = @identity.active_user_by_name(pool, selected.get_name("actor"))
    let scope = @runtime.require_run_author(pool, actor, repo)
    @repository.with_repository_write(pool, root, actor, scope, (scope, dir) => {
      let row = pool.with_client(c => {
        c.query_one("SELECT * FROM pipeline_workflow_event WHERE id=?", params=[
          id,
        ])
      })
      if (row.get_name("state") : String) != "pending" {
        return
      }
      let branch : String = row.get_name("branch")
      let name : String = row.get_name("event_name")
      let pin = "refs/moonhub/workflow-events/" + id.to_string()
      let sha = match (row.get_name("commit_sha") : String?) {
        Some(sha) => sha
        None => {
          guard !branch.is_empty() && branch != "HEAD" else {
            raise @domain.BadRequest(
              message="completion workflows require a configured default branch",
            )
          }
          let (code, value) = @gitops.merge_git_command(dir, [
            "rev-parse", "--verify", "--quiet", pin,
          ])
          if code == 0 {
            value.trim().to_owned()
          } else {
            @gitops.branch_sha(dir, branch)
          }
        }
      }
      guard @gitops.valid_commit_sha(sha) else {
        raise @domain.BadRequest(message="invalid workflow event commit")
      }
      ignore(@gitops.merge_git(dir, ["update-ref", "--no-deref", pin, sha]))
      pool.with_client(c => {
        ignore(
          c.execute(
            "UPDATE pipeline_workflow_event SET commit_sha=? WHERE id=? AND commit_sha IS NULL",
            params=[sha, id],
          ),
        )
      })
      let event : Map[String, Json] = @json.from_json(
        @json.parse((row.get_name("payload_json") : String)),
      )
      let output = @gitops.merge_git(dir, ["ls-tree", sha, ".github/workflows/"])
      let paths = @domain.split_lines(output)
        .iter()
        .filter_map(line => line.split_once("\t").map(p => p.1.to_owned()))
        .filter(p => p.has_suffix(".yml") || p.has_suffix(".yaml"))
        .collect()
      guard paths.length() <= 64 else {
        raise @domain.BadRequest(
          message="event revision contains more than 64 workflows",
        )
      }
      let mut changes : Array[String]? = None
      let mut changes_loaded = false
      for path in paths {
        if pool.with_client(c => {
            c.query_opt(
              "SELECT id FROM pipeline_run WHERE workflow_event_id=? AND workflow_path=?",
              params=[id, path],
            )
          })
          is Some(_) {
          continue
        }
        try {
          @runtime.validate_workflow_path(path)
          let source = read_workflow_source(dir, sha, path)
          let trigger = @workflow.triggers(source)
          let mut head_ref = ""
          let mut base_ref = ""
          let matches = match name {
            "repository_dispatch" =>
              match event.get("action") {
                Some(String(action)) =>
                  trigger.matches_repository_dispatch(action)
                _ => false
              }
            "workflow_run" =>
              match event.get("workflow_run") {
                Some(
                  { "name": String(name), "head_branch": String(branch), .. },
                ) => trigger.matches_workflow_run(name, branch)
                _ => false
              }
            "pull_request" =>
              match (event.get("action"), event.get("pull_request")) {
                (
                  Some(String(action)),
                  Some(
                    {
                      "head": {
                        "ref": String(head),
                        "sha": String(head_sha),
                        ..
                      },
                      "base": {
                        "ref": String(base),
                        "sha": String(base_sha),
                        ..
                      },
                      ..
                    },
                  ),
                ) => {
                  head_ref = head
                  base_ref = base
                  if !changes_loaded &&
                    (
                      !trigger.pull_request_filters.paths.is_empty() ||
                      !trigger.pull_request_filters.paths_ignore.is_empty()
                    ) {
                    changes = try {
                      if @gitops.valid_commit_sha(head_sha) &&
                        @gitops.valid_commit_sha(base_sha) {
                        let (code, output) = @gitops.merge_git_command(dir, [
                          "merge-base", "--all", base_sha, head_sha,
                        ])
                        let bases = @domain.split_lines(output)
                        if code == 0 && bases.length() == 1 {
                          changed_paths(dir, bases[0], head_sha)
                        } else {
                          None
                        }
                      } else {
                        None
                      }
                    } catch {
                      @gitops.Failure(_) => None
                      err => raise err
                    }
                    changes_loaded = true
                  }
                  trigger.matches_pull_request(
                    action,
                    branch=base,
                    paths=changes,
                  )
                }
                _ => false
              }
            _ => false
          }
          if !matches {
            continue
          }
          let context : @workflow.RunContext = {
            repository: repo.owner + "/" + repo.name,
            sha,
            event_name: name,
            head_ref,
            base_ref,
            inputs: Map([]),
            variables: Map([]),
            release_tag: None,
            event: Some(event),
          }
          let definition = @workflow.resolve_context(
            read_workflow_definition(dir, sha, source),
            context,
          )
          let run_pin = pin + "/" + @identity.hash_token(path)
          // Git refs cannot have both a name and its children, so use a separate namespace.
          let run_pin = run_pin.replace_all(
            old="refs/moonhub/workflow-events/",
            new="refs/moonhub/pipelines/events/",
          )
          ignore(
            @gitops.merge_git(dir, ["update-ref", "--no-deref", run_pin, sha]),
          )
          ignore(@runtime.require_run_author(pool, actor, repo))
          pool.with_client(c => {
            c.with_transaction(tx => {
              ignore(
                insert_run_snapshot(
                  tx,
                  scope.id,
                  actor.id,
                  path,
                  if definition.name.is_empty() {
                    path
                  } else {
                    definition.name
                  },
                  branch,
                  sha,
                  run_pin,
                  source,
                  definition,
                  context=Some(context),
                  workflow_event_id=id,
                ),
              )
            })
          })
        } catch {
          @workflow.InvalidWorkflow(message) | @domain.BadRequest(message~) =>
            if diagnostic.is_empty() {
              diagnostic = path + ": " + message
            }
          err => raise err
        }
      }
    })
  } catch {
    @domain.BadRequest(message~)
    | @domain.NotFound(message~)
    | @domain.Forbidden(message~)
    | @domain.Unauthorized(message~) => diagnostic = message
    err => raise err
  }
  pool.with_client(c => {
    ignore(
      c.execute(
        "UPDATE pipeline_workflow_event SET state='processed',last_error=? WHERE id=?",
        params=[diagnostic, id],
      ),
    )
  })
  true
}
