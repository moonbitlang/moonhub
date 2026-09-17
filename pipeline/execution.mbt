///|
let attempt_select : String =
  #|SELECT a.*, j.run_id, j.job_key, r.repository_id, r.requested_by_user_id,
  #|  r.cancel_requested, r.definition_json, r.definition_version, r.commit_sha,
  #|  repo.name AS repo_name, t.name_key AS owner_name
  #|FROM pipeline_job_attempt a JOIN pipeline_job j ON j.id = a.job_id
  #|JOIN pipeline_run r ON r.id = j.run_id
  #|JOIN repository repo ON repo.id = r.repository_id JOIN team t ON t.id = repo.team_id

///|
fn check_version(version : Int) -> Unit raise {
  guard version == @protocol.version else {
    raise @domain.BadRequest(message="unsupported runner protocol version")
  }
}

///|
fn attempt_row(
  tx : @database.DbTransaction,
  id : Int64,
  token : String,
) -> @database.DbRow raise {
  check_token(token)
  let row = tx.query_opt(
    "\{attempt_select} WHERE a.id = ? AND a.token_hash = ?",
    params=[id, @identity.hash_token(token)],
  )
  guard row is Some(row) else {
    raise @domain.Unauthorized(message="invalid runner credentials")
  }
  row
}

///|
pub fn Coordinator::authenticate_attempt(
  self : Coordinator,
  id : Int64,
  token : String,
) -> Unit raise {
  check_token(token)
  self.pool.with_client(client => {
    guard client.query_opt(
        "SELECT id FROM pipeline_job_attempt WHERE id = ? AND token_hash = ?",
        params=[id, @identity.hash_token(token)],
      )
      is Some(_) else {
      raise @domain.Unauthorized(message="invalid runner credentials")
    }
  })
}

///|
fn attempt_job(row : @database.DbRow) -> @workflow.Job raise {
  guard (row.get_name("definition_version") : Int64) ==
    @workflow.format_version.to_int64() else {
    raise InvalidRecord
  }
  let text : String = row.get_name("definition_json")
  let definition : @workflow.Workflow = @json.from_json(@json.parse(text))
  let key : String = row.get_name("job_key")
  guard definition.jobs.iter().find_first(job => job.id == key) is Some(job) else {
    raise InvalidRecord
  }
  job
}

///|
fn attempt_authorized(
  tx : @database.DbTransaction,
  row : @database.DbRow,
) -> Bool raise {
  let actor_id : Int64 = row.get_name("requested_by_user_id")
  let repository_id : Int64 = row.get_name("repository_id")
  let provider_id : Int64? = row.get_name("provider_id")
  guard provider_id is Some(provider_id) else { return false }
  tx.query_opt(
    "SELECT p.id FROM pipeline_provider p JOIN pipeline_provider_repository g ON g.provider_id = p.id JOIN repository repo ON repo.id = g.repository_id JOIN \"user\" u ON u.id = ? LEFT JOIN team_member tm ON tm.user_id = u.id AND tm.team_id = repo.team_id WHERE p.id = ? AND g.repository_id = ? AND p.revoked = 0 AND repo.ready = 1 AND u.status = 'active' AND (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin'))",
    params=[actor_id, provider_id, repository_id],
  )
  is Some(_)
}

///|
fn load_live_attempt(
  tx : @database.DbTransaction,
  id : Int64,
  token : String,
  now : Int64,
) -> @database.DbRow raise {
  let row = attempt_row(tx, id, token)
  let status : String = row.get_name("status")
  let lease : Int64? = row.get_name("lease_until_ms")
  let deadline : Int64? = row.get_name("deadline_ms")
  let cancel_at : Int64? = row.get_name("cancel_at_ms")
  guard status != "completed" &&
    lease is Some(lease) &&
    lease > now &&
    !(deadline is Some(value) && value <= now) &&
    !(cancel_at is Some(value) && value + @protocol.cancel_grace_ms <= now) else {
    raise Conflict("attempt is completed or its lease expired")
  }
  let cancelled : Bool = row.get_name("cancel_requested")
  if cancelled || !attempt_authorized(tx, row) {
    let _ = tx.execute(
      "UPDATE pipeline_job_attempt SET cancel_at_ms = COALESCE(cancel_at_ms, ?) WHERE id = ?",
      params=[now, id],
    )
  }
  attempt_row(tx, id, token)
}

///|
fn lease_state(
  row : @database.DbRow,
  now : Int64,
) -> @protocol.LeaseState raise {
  {
    version: @protocol.version,
    execution_id: (row.get_name("execution_id") : String?).unwrap_or(""),
    attempt_id: row.get_name("id"),
    state: row.get_name("status"),
    lease_until_ms: (row.get_name("lease_until_ms") : Int64?).unwrap_or(0L),
    server_time_ms: now,
    deadline_ms: (row.get_name("deadline_ms") : Int64?).unwrap_or(0L),
    cancel_requested: (row.get_name("cancel_at_ms") : Int64?) is Some(_),
    log_sequence: row.get_name("log_sequence"),
    conclusion: (row.get_name("conclusion") : String?).unwrap_or(""),
  }
}

///|
fn renew_lease(
  tx : @database.DbTransaction,
  row : @database.DbRow,
  now : Int64,
) -> Unit raise {
  let mut until = now + @protocol.lease_ms
  if (row.get_name("deadline_ms") : Int64?) is Some(deadline) &&
    deadline < until {
    until = deadline
  }
  if (row.get_name("cancel_at_ms") : Int64?) is Some(cancel_at) &&
    cancel_at + @protocol.cancel_grace_ms < until {
    until = cancel_at + @protocol.cancel_grace_ms
  }
  let id : Int64 = row.get_name("id")
  let _ = tx.execute(
    "UPDATE pipeline_job_attempt SET lease_until_ms = ? WHERE id = ?",
    params=[until, id],
  )
}

///|
fn finalize_run(tx : @database.DbTransaction, run_id : Int64) -> Unit raise {
  guard tx.query_opt(
      "SELECT id FROM pipeline_job WHERE run_id = ? AND status <> 'completed' LIMIT 1",
      params=[run_id],
    )
    is None else {
    return
  }
  let row = tx.query_one(
    "SELECT cancel_requested FROM pipeline_run WHERE id = ?",
    params=[run_id],
  )
  let cancelled : Bool = row.get_name("cancel_requested")
  let conclusions : Array[String] = tx
    .query_all("SELECT conclusion FROM pipeline_job WHERE run_id = ?", params=[
      run_id,
    ])
    .map(row => row.get_name("conclusion"))
  let conclusion = if conclusions.contains("lost") {
    "lost"
  } else if cancelled || conclusions.contains("cancelled") {
    "cancelled"
  } else if conclusions.contains("timed_out") {
    "timed_out"
  } else if conclusions.contains("failure") {
    "failure"
  } else {
    "success"
  }
  let _ = tx.execute(
    "UPDATE pipeline_run SET status = 'completed', conclusion = ?, updated_at = datetime('now') WHERE id = ? AND status <> 'completed'",
    params=[conclusion, run_id],
  )
}

///|
fn finish_attempt(
  tx : @database.DbTransaction,
  row : @database.DbRow,
  conclusion : String,
) -> Unit raise {
  let id : Int64 = row.get_name("id")
  let job_id : Int64 = row.get_name("job_id")
  let run_id : Int64 = row.get_name("run_id")
  flush_log_tails(tx, id)
  let _ = tx.execute(
    "UPDATE pipeline_step SET state = ?, exit_code = -1 WHERE attempt_id = ? AND state = 'running'",
    params=[if conclusion == "success" { "lost" } else { conclusion }, id],
  )
  let _ = tx.execute(
    "UPDATE pipeline_step SET state = 'skipped' WHERE attempt_id = ? AND state = 'pending'",
    params=[id],
  )
  let _ = tx.execute(
    "UPDATE pipeline_job_attempt SET status = 'completed', conclusion = ?, finished_at = datetime('now') WHERE id = ? AND status <> 'completed'",
    params=[conclusion, id],
  )
  let _ = tx.execute(
    "UPDATE pipeline_job SET status = 'completed', conclusion = ? WHERE id = ? AND status <> 'completed'",
    params=[conclusion, job_id],
  )
  finalize_run(tx, run_id)
}

///|
pub fn Coordinator::expire_attempts(self : Coordinator) -> Int raise {
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let now = (self.clock)()
        let rows = tx.query_all(
          "SELECT a.*, j.run_id FROM pipeline_job_attempt a JOIN pipeline_job j ON j.id = a.job_id WHERE a.status <> 'completed' AND (a.lease_until_ms IS NULL OR a.lease_until_ms <= ? OR a.deadline_ms <= ? OR a.cancel_at_ms + ? <= ?) ORDER BY a.lease_until_ms, a.id LIMIT 100",
          params=[now, now, @protocol.cancel_grace_ms, now],
        )
        for row in rows {
          let deadline : Int64? = row.get_name("deadline_ms")
          let cancel_at : Int64? = row.get_name("cancel_at_ms")
          let lease : Int64 = (row.get_name("lease_until_ms") : Int64?).unwrap_or(
            0L,
          )
          let timed_out = deadline is Some(deadline) &&
            deadline <= now &&
            deadline <= lease &&
            cancel_at is None
          finish_attempt(tx, row, if timed_out { "timed_out" } else { "lost" })
        }
        rows.length()
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::claim(
  self : Coordinator,
  token : String,
  request : @protocol.ClaimRequest,
) -> @protocol.Assignment? raise {
  check_version(request.version)
  check_token(request.attempt_token)
  guard request.request_id.length() == 32 &&
    request.request_id
    .iter()
    .all(ch => ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f')) else {
    raise @domain.BadRequest(
      message="request_id must be 32 lowercase hexadecimal characters",
    )
  }
  self.authenticate_provider(token)
  ignore(self.expire_attempts())
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let now = (self.clock)()
        let provider = authenticate_provider(tx, token)
        let provider_id : Int64 = provider.get_name("id")
        let hash = @identity.hash_token(request.attempt_token)
        let previous = tx.query_opt(
          "SELECT id, token_hash FROM pipeline_job_attempt WHERE provider_id = ? AND request_id = ?",
          params=[provider_id, request.request_id],
        )
        let row = match previous {
          Some(previous) => {
            guard (previous.get_name("token_hash") : String) == hash else {
              raise Conflict(
                "claim request was reused with different credentials",
              )
            }
            let id : Int64 = previous.get_name("id")
            let row = load_live_attempt(tx, id, request.attempt_token, now)
            guard (row.get_name("cancel_at_ms") : Int64?) is None else {
              raise Conflict("claim has been cancelled")
            }
            row
          }
          None => {
            guard tx.query_opt(
                "SELECT id FROM pipeline_provider WHERE token_hash = ?",
                params=[hash],
              )
              is None &&
              tx.query_opt(
                "SELECT id FROM pipeline_job_attempt WHERE token_hash = ?",
                params=[hash],
              )
              is None else {
              raise Conflict(
                "attempt credentials must be unique and distinct from provider credentials",
              )
            }
            if (provider.get_name("paused") : Bool) ||
              tx.query_opt(
                "SELECT id FROM pipeline_job_attempt WHERE provider_id = ? AND status <> 'completed' LIMIT 1",
                params=[provider_id],
              )
              is Some(_) {
              return None
            }
            let job = tx.query_opt(
              (
                #|SELECT j.id, j.run_id FROM pipeline_job j JOIN pipeline_run r ON r.id = j.run_id
                #|JOIN pipeline_provider_repository g ON g.repository_id = r.repository_id AND g.provider_id = ?
                #|JOIN repository repo ON repo.id = r.repository_id JOIN "user" u ON u.id = r.requested_by_user_id
                #|LEFT JOIN team_member tm ON tm.user_id = u.id AND tm.team_id = repo.team_id
                #|WHERE j.status = 'queued' AND r.status = 'queued' AND r.cancel_requested = 0 AND repo.ready = 1
                #|AND r.definition_version = ?
                #|AND u.status = 'active' AND (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin'))
                #|AND (SELECT COUNT(*) FROM pipeline_job sibling WHERE sibling.run_id = r.id) = 1
                #|AND NOT EXISTS (SELECT 1 FROM pipeline_job_need n WHERE n.run_id = r.id AND n.job_key = j.job_key)
                #|AND NOT EXISTS (SELECT 1 FROM pipeline_job_label label WHERE label.job_id = j.id
                #|  AND NOT EXISTS (SELECT 1 FROM pipeline_provider_label p WHERE p.provider_id = ? AND p.label = label.label))
                #|ORDER BY j.id LIMIT 1
              ),
              params=[
                provider_id,
                @workflow.format_version.to_int64(),
                provider_id,
              ],
            )
            guard job is Some(job) else { return None }
            let job_id : Int64 = job.get_name("id")
            let run_id : Int64 = job.get_name("run_id")
            guard tx.execute(
                "UPDATE pipeline_job SET status = 'leased' WHERE id = ? AND status = 'queued'",
                params=[job_id],
              ) ==
              1 else {
              raise Conflict("job was already claimed")
            }
            let id : Int64 = tx
              .query_one(
                "INSERT INTO pipeline_job_attempt (job_id, number, status, provider_id, request_id, token_hash, lease_until_ms) SELECT ?, COALESCE(MAX(number), 0) + 1, 'leased', ?, ?, ?, ? FROM pipeline_job_attempt WHERE job_id = ? RETURNING id",
                params=[
                  job_id,
                  provider_id,
                  request.request_id,
                  hash,
                  now + @protocol.lease_ms,
                  job_id,
                ],
              )
              .get_name("id")
            let _ = tx.execute(
              "UPDATE pipeline_run SET status = 'running', updated_at = datetime('now') WHERE id = ?",
              params=[run_id],
            )
            attempt_row(tx, id, request.attempt_token)
          }
        }
        let owner : String = row.get_name("owner_name")
        let name : String = row.get_name("repo_name")
        let job = attempt_job(row)
        Some({
          version: @protocol.version,
          attempt_id: row.get_name("id"),
          run_id: row.get_name("run_id"),
          job_id: row.get_name("job_id"),
          repository: "\{owner}/\{name}",
          commit_sha: row.get_name("commit_sha"),
          lease_until_ms: row.get_name("lease_until_ms"),
          server_time_ms: now,
          state: row.get_name("status"),
          job: {
            id: job.id,
            name: job.name,
            runs_on: job.runs_on,
            timeout_minutes: job.timeout_minutes,
            steps: job.steps.map(step => {
              id: step.id,
              name: step.name,
              run: step.run,
              shell: step.shell.unwrap_or(""),
              working_directory: step.working_directory,
              env: step.env,
              timeout_minutes: step.timeout_minutes.unwrap_or(0),
            }),
          },
        })
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::start(
  self : Coordinator,
  id : Int64,
  token : String,
  version : Int,
  execution_id? : String = "",
) -> @protocol.LeaseState raise {
  check_version(version)
  guard execution_id.is_empty() ||
    (
      execution_id.length() == 32 &&
      execution_id
      .iter()
      .all(ch => ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f'))
    ) else {
    raise @domain.BadRequest(message="invalid execution id")
  }
  self.authenticate_attempt(id, token)
  ignore(self.expire_attempts())
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let now = (self.clock)()
        let row = load_live_attempt(tx, id, token, now)
        let bound : String? = row.get_name("execution_id")
        if (row.get_name("status") : String) == "running" || bound is Some(_) {
          guard bound.unwrap_or("") == execution_id else {
            raise Conflict("attempt belongs to a different execution instance")
          }
        } else if !execution_id.is_empty() {
          let _ = tx.execute(
            "UPDATE pipeline_job_attempt SET execution_id = ? WHERE id = ?",
            params=[execution_id, id],
          )
          for ordinal, step in attempt_job(row).steps {
            let _ = tx.execute(
              "INSERT INTO pipeline_step (attempt_id, step_id, ordinal) VALUES (?, ?, ?)",
              params=[id, step.id, ordinal.to_int64()],
            )
          }
        }
        if (row.get_name("status") : String) == "leased" &&
          (row.get_name("cancel_at_ms") : Int64?) is None {
          let job = attempt_job(row)
          let job_id : Int64 = row.get_name("job_id")
          let _ = tx.execute(
            "UPDATE pipeline_job_attempt SET status = 'running', started_at_ms = ?, deadline_ms = ? WHERE id = ?",
            params=[now, now + job.timeout_minutes.to_int64() * 60000L, id],
          )
          let _ = tx.execute(
            "UPDATE pipeline_job SET status = 'running' WHERE id = ?",
            params=[job_id],
          )
        }
        renew_lease(tx, attempt_row(tx, id, token), now)
        lease_state(attempt_row(tx, id, token), now)
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::heartbeat(
  self : Coordinator,
  id : Int64,
  token : String,
  version : Int,
) -> @protocol.LeaseState raise {
  check_version(version)
  self.authenticate_attempt(id, token)
  ignore(self.expire_attempts())
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let now = (self.clock)()
        let row = load_live_attempt(tx, id, token, now)
        // A provider cannot indefinitely reserve work without starting its runner.
        if (row.get_name("status") : String) == "running" ||
          (row.get_name("cancel_at_ms") : Int64?) is Some(_) {
          renew_lease(tx, row, now)
        }
        lease_state(attempt_row(tx, id, token), now)
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::complete(
  self : Coordinator,
  id : Int64,
  token : String,
  request : @protocol.CompleteRequest,
) -> @protocol.LeaseState raise {
  check_version(request.version)
  guard ["success", "failure", "cancelled", "timed_out"].contains(
    request.conclusion,
  ) else {
    raise @domain.BadRequest(message="invalid attempt conclusion")
  }
  self.authenticate_attempt(id, token)
  ignore(self.expire_attempts())
  let hash = @identity.hash_token(ToJson::to_json(request).stringify())
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = attempt_row(tx, id, token)
        if (row.get_name("status") : String) == "completed" {
          guard (row.get_name("result_hash") : String?) == Some(hash) else {
            raise Conflict("attempt already completed with a different result")
          }
          return lease_state(row, (self.clock)())
        }
        let row = load_live_attempt(tx, id, token, (self.clock)())
        guard (row.get_name("log_sequence") : Int64) ==
          request.last_log_sequence else {
          raise Conflict("completion does not match acknowledged log sequence")
        }
        guard (row.get_name("status") : String) == "running" ||
          request.conclusion == "failure" ||
          request.conclusion == "cancelled" else {
          raise Conflict("attempt has not started")
        }
        if request.conclusion == "success" &&
          (row.get_name("execution_id") : String?) is Some(_) {
          guard tx.query_opt(
              "SELECT step_id FROM pipeline_step WHERE attempt_id = ? AND state <> 'success' LIMIT 1",
              params=[id],
            )
            is None else {
            raise Conflict("not all steps succeeded")
          }
        }
        let _ = tx.execute(
          "UPDATE pipeline_job_attempt SET result_hash = ?, reported_conclusion = ? WHERE id = ?",
          params=[hash, request.conclusion, id],
        )
        let conclusion = if (row.get_name("cancel_at_ms") : Int64?) is Some(_) {
          "cancelled"
        } else {
          request.conclusion
        }
        finish_attempt(tx, row, conclusion)
        lease_state(attempt_row(tx, id, token), (self.clock)())
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::cancel_run(
  self : Coordinator,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
) -> Unit raise {
  ignore(require_run_author(self.pool, actor, repo))
  let run = get_run(self.pool, actor, repo, number)
  let now = (self.clock)()
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let _ = tx.execute(
          "UPDATE pipeline_run SET cancel_requested = 1, updated_at = datetime('now') WHERE id = ? AND status <> 'completed'",
          params=[run.id],
        )
        let _ = tx.execute(
          "UPDATE pipeline_job SET status = 'completed', conclusion = 'cancelled' WHERE run_id = ? AND status IN ('queued', 'waiting')",
          params=[run.id],
        )
        let _ = tx.execute(
          "UPDATE pipeline_job_attempt SET cancel_at_ms = COALESCE(cancel_at_ms, ?) WHERE status <> 'completed' AND job_id IN (SELECT id FROM pipeline_job WHERE run_id = ?)",
          params=[now, run.id],
        )
        finalize_run(tx, run.id)
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::start_lease_worker(
  self : Coordinator,
  group : @async.TaskGroup[Unit],
) -> Unit {
  group.spawn_bg(no_wait=true, () => {
    for ;; {
      ignore(self.expire_attempts()) catch {
        _ => println("pipeline lease reconciliation failed")
      }
      @async.sleep(2000)
    }
  })
}
