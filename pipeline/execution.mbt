///|
let eligible_provider_jobs : String =
  #|SELECT j.id, j.run_id FROM pipeline_job j JOIN pipeline_run r ON r.id = j.run_id
  #|JOIN pipeline_provider provider ON provider.id = ?
  #|JOIN repository repo ON repo.id = r.repository_id JOIN "user" u ON u.id = r.requested_by_user_id
  #|LEFT JOIN team_member tm ON tm.user_id = u.id AND tm.team_id = repo.team_id
  #|WHERE j.status = 'queued' AND r.status IN ('queued', 'running') AND r.cancel_requested = 0 AND repo.ready = 1
  #|AND r.definition_version IN (1, 2, 3, 4, 5, 6, ?)
  #|AND NOT EXISTS (SELECT 1 FROM pipeline_run_schedule s WHERE s.run_id=r.id AND s.admitted=0)
  #|AND (j.matrix_group='' OR (SELECT COUNT(*) FROM pipeline_job siblings WHERE siblings.run_id=j.run_id AND siblings.matrix_group=j.matrix_group AND siblings.status IN ('leased','running')) < j.max_parallel)
  #|AND (r.merge_check_id IS NULL OR EXISTS (SELECT 1 FROM merge_check c JOIN merge_request m ON m.id = c.merge_request_id WHERE c.id = r.merge_check_id AND m.status = 'open' AND m.draft = 0 AND c.version = m.current_version AND c.generation = m.check_generation AND c.run_number = r.number AND (c.automatic = 1 OR EXISTS (SELECT 1 FROM branch_required_check b WHERE b.repository_id = m.repository_id AND b.branch = m.target_branch AND b.workflow_path = c.workflow_path))))
  #|AND u.status = 'active' AND (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin'))
  #|AND (provider.repository_scope = 'all' OR EXISTS (SELECT 1 FROM pipeline_provider_repository g WHERE g.provider_id = provider.id AND g.repository_id = r.repository_id))
  #|AND EXISTS (SELECT 1 FROM pipeline_provider_label os WHERE os.provider_id=provider.id AND os.label=
  #|  CASE WHEN EXISTS (SELECT 1 FROM pipeline_job_label os WHERE os.job_id=j.id AND os.label='windows') THEN 'windows'
  #|  WHEN EXISTS (SELECT 1 FROM pipeline_job_label os WHERE os.job_id=j.id AND os.label='macos') THEN 'macos' ELSE 'linux' END)
  #|AND NOT EXISTS (SELECT 1 FROM pipeline_job_label label WHERE label.job_id = j.id
  #|  AND NOT EXISTS (SELECT 1 FROM pipeline_provider_label p WHERE p.provider_id = ? AND p.label = label.label))

///|
let attempt_select : String =
  #|SELECT a.*, j.run_id, j.job_key, r.repository_id, r.requested_by_user_id,
  #|  r.cancel_requested, r.definition_json, r.definition_version, r.commit_sha,
  #|  repo.name AS repo_name, t.name_key AS owner_name
  #|FROM pipeline_job_attempt a JOIN pipeline_job j ON j.id = a.job_id
  #|JOIN pipeline_run r ON r.id = j.run_id
  #|JOIN repository repo ON repo.id = r.repository_id JOIN team t ON t.id = repo.team_id

///|
fn check_version(version : Int32) -> Unit raise {
  guard version == @protocol.version else {
    raise @domain.BadRequest(message="unsupported runner protocol version")
  }
}

///|
fn parse_protocol_int64(value : String, message : String) -> Int64 raise {
  match @protocol.parse_decimal(value) {
    Some(value) => value
    None => raise @domain.BadRequest(message~)
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
  guard [1L, 2L, 3L, 4L, 5L, 6L, @workflow.format_version.to_int64()].contains(
    row.get_name("definition_version"),
  ) else {
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
  let run_id : Int64 = row.get_name("run_id")
  guard tx.query_opt(
      "SELECT r.id FROM pipeline_run r WHERE r.id = ? AND (r.merge_check_id IS NULL OR EXISTS (SELECT 1 FROM merge_check c JOIN merge_request m ON m.id = c.merge_request_id WHERE c.id = r.merge_check_id AND m.status = 'open' AND m.draft = 0 AND c.version = m.current_version AND c.generation = m.check_generation AND c.run_number = r.number AND (c.automatic = 1 OR EXISTS (SELECT 1 FROM branch_required_check b WHERE b.repository_id = m.repository_id AND b.branch = m.target_branch AND b.workflow_path = c.workflow_path))))",
      params=[run_id],
    )
    is Some(_) else {
    return false
  }
  tx.query_opt(
    "SELECT p.id FROM pipeline_provider p JOIN repository repo ON repo.id = ? JOIN \"user\" u ON u.id = ? LEFT JOIN team_member tm ON tm.user_id = u.id AND tm.team_id = repo.team_id WHERE p.id = ? AND (p.repository_scope = 'all' OR EXISTS (SELECT 1 FROM pipeline_provider_repository g WHERE g.provider_id = p.id AND g.repository_id = repo.id)) AND p.revoked = 0 AND repo.ready = 1 AND u.status = 'active' AND (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin'))",
    params=[repository_id, actor_id, provider_id],
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
    attempt_id: (row.get_name("id") : Int64).to_string(),
    state: row.get_name("status"),
    lease_until_ms: (row.get_name("lease_until_ms") : Int64?)
    .unwrap_or(0L)
    .to_string(),
    server_time_ms: now.to_string(),
    deadline_ms: (row.get_name("deadline_ms") : Int64?)
    .unwrap_or(0L)
    .to_string(),
    cancel_requested: (row.get_name("cancel_at_ms") : Int64?) is Some(_),
    log_sequence: (row.get_name("log_sequence") : Int64).to_string(),
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
  ignore(
    tx.execute("UPDATE pipeline_provider SET last_seen_ms = ? WHERE id = ?", params=[
      now,
      (row.get_name("provider_id") : Int64),
    ]),
  )
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
  } else if cancelled {
    "cancelled"
  } else if conclusions.contains("timed_out") {
    "timed_out"
  } else if conclusions.contains("failure") {
    "failure"
  } else if conclusions.contains("cancelled") {
    "cancelled"
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
  now : Int64,
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
  cancel_matrix_siblings(tx, job_id, conclusion, now)
  advance_run_jobs(tx, run_id)
  finalize_run(tx, run_id)
}

///|
pub fn Coordinator::expire_attempts(self : Coordinator) -> Int32 raise {
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
          finish_attempt(
            tx,
            row,
            if timed_out {
              "timed_out"
            } else {
              "lost"
            },
            now,
          )
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
  check_token(token)
  ignore(self.expire_attempts())
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let now = (self.clock)()
        let worker = tx.query_opt(
          "SELECT id FROM pipeline_worker WHERE token_hash=?",
          params=[@identity.hash_token(token)],
        )
        let worker_id : Int64? = worker.map(row => row.get_name("id"))
        let provider = if worker_id is Some(_) {
          let w = authenticate_worker(tx, token)
          tx.query_one("SELECT * FROM pipeline_provider WHERE id=?", params=[
            (w.get_name("provider_id") : Int64),
          ])
        } else {
          let p = authenticate_provider(tx, token)
          guard (p.get_name("mode") : String).is_empty() else {
            raise @domain.Forbidden(
              message="Managed controllers cannot claim tasks.",
            )
          }
          p
        }
        let provider_id : Int64 = provider.get_name("id")
        let runner_os = request.runner_os.unwrap_or("linux")
        guard ["linux", "windows", "macos"].contains(runner_os) else {
          raise @domain.BadRequest(
            message="Unsupported runner operating system.",
          )
        }
        guard tx.query_opt(
            "SELECT label FROM pipeline_provider_label WHERE provider_id=? AND label=?",
            params=[provider_id, runner_os],
          )
          is Some(_) else {
          raise @domain.Forbidden(
            message="Runner operating system does not match provider labels.",
          )
        }
        ignore(
          tx.execute(
            "UPDATE pipeline_provider SET last_seen_ms = ? WHERE id = ?",
            params=[now, provider_id],
          ),
        )
        advance_all_runs(tx)
        let hash = @identity.hash_token(request.attempt_token)
        let previous = tx.query_opt(
          "SELECT id, token_hash FROM pipeline_job_attempt WHERE provider_id = ? AND request_id = ? AND COALESCE(worker_id,0) = ?",
          params=[provider_id, request.request_id, worker_id.unwrap_or(0L)],
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
            if worker_id is Some(_) {
              let w = authenticate_worker(tx, token)
              guard !(w.get_name("draining") : Bool) &&
                (w.get_name("state") : String) == "ready" &&
                (w.get_name("applied_revision") : Int64) ==
                (w.get_name("config_revision") : Int64) &&
                (provider.get_name("applied_revision") : Int64) ==
                (provider.get_name("config_revision") : Int64) else {
                return None
              }
            }
            guard tx.query_opt(
                "SELECT id FROM pipeline_provider WHERE token_hash = ? OR registration_hash = ?",
                params=[hash, hash],
              )
              is None &&
              tx.query_opt(
                "SELECT id FROM pipeline_job_attempt WHERE token_hash = ?",
                params=[hash],
              )
              is None &&
              tx.query_opt(
                "SELECT id FROM pipeline_worker WHERE token_hash=?",
                params=[hash],
              )
              is None else {
              raise Conflict(
                "attempt credentials must be unique and distinct from provider and worker credentials",
              )
            }
            if (provider.get_name("paused") : Bool) ||
              tx.query_opt(
                "SELECT id FROM pipeline_job_attempt WHERE provider_id = ? AND COALESCE(worker_id,0) = ? AND status <> 'completed' LIMIT 1",
                params=[provider_id, worker_id.unwrap_or(0L)],
              )
              is Some(_) {
              return None
            }
            let job = tx.query_opt(
              eligible_provider_jobs + " ORDER BY j.id LIMIT 1",
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
            if worker_id is Some(worker_id) {
              ignore(
                tx.execute(
                  "UPDATE pipeline_job_attempt SET worker_id=? WHERE id=?",
                  params=[worker_id, id],
                ),
              )
              ignore(
                tx.execute(
                  "UPDATE pipeline_worker SET state='busy' WHERE id=?",
                  params=[worker_id],
                ),
              )
            }
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
        let captured = tx.query_one(
          "SELECT r.source_branch,r.workflow_name,r.context_json,(SELECT name_key FROM \"user\" WHERE id=r.requested_by_user_id) AS actor_name,m.number AS mr_number FROM pipeline_run r LEFT JOIN merge_check c ON c.id=r.merge_check_id LEFT JOIN merge_request m ON m.id=c.merge_request_id WHERE r.id = ?",
          params=[(row.get_name("run_id") : Int64)],
        )
        let context : Map[String, String] = {
          "ref": if (captured.get_name("mr_number") : Int64?) is Some(number) {
            "refs/pull/" + number.to_string() + "/merge"
          } else {
            "refs/heads/" + (captured.get_name("source_branch") : String)
          },
          "workflow": captured.get_name("workflow_name"),
        }
        if (row.get_name("definition_version") : Int64) >= 7L {
          context["actor"] = captured.get_name("actor_name")
        }
        let mut variables : Map[String, String] = Map([])
        let mut dispatch_inputs : Map[String, Json] = Map([])
        let mut event : Map[String, Json] = Map([])
        if (captured.get_name("context_json") : String?) is Some(text) {
          let saved : @workflow.RunContext = @json.from_json(@json.parse(text))
          context["event_name"] = saved.event_name
          context["head_ref"] = saved.head_ref
          context["base_ref"] = saved.base_ref
          if (row.get_name("definition_version") : Int64) >= 6L {
            variables = saved.variables
          }
          if (row.get_name("definition_version") : Int64) >= 5L {
            dispatch_inputs = saved.inputs
            event = run_event_context(saved, event_ref=context["ref"])
          }
        }
        Some({
          version: if (row.get_name("definition_version") : Int64) >= 7L {
            @protocol.oidc_assignment_version
          } else if (row.get_name("definition_version") : Int64) >= 6L {
            @protocol.variable_assignment_version
          } else if (row.get_name("definition_version") : Int64) >= 5L {
            @protocol.dispatch_assignment_version
          } else if (row.get_name("definition_version") : Int64) >= 4L {
            @protocol.dataflow_assignment_version
          } else if (row.get_name("definition_version") : Int64) >= 3L {
            @protocol.scheduling_assignment_version
          } else if (row.get_name("definition_version") : Int64) >= 2L {
            @protocol.remote_assignment_version
          } else if job.steps.any(step => !step.secret_env.is_empty()) {
            @protocol.secret_assignment_version
          } else if job.steps.any(step => {
              step.uses == Some("moonhub/setup-moonbit@v1")
            }) {
            @protocol.toolchain_assignment_version
          } else if job.steps.any(step => step.uses is Some(_)) {
            @protocol.action_assignment_version
          } else {
            @protocol.version
          },
          attempt_id: (row.get_name("id") : Int64).to_string(),
          run_id: (row.get_name("run_id") : Int64).to_string(),
          job_id: (row.get_name("job_id") : Int64).to_string(),
          repository: "\{owner}/\{name}",
          commit_sha: row.get_name("commit_sha"),
          lease_until_ms: (row.get_name("lease_until_ms") : Int64).to_string(),
          server_time_ms: now.to_string(),
          state: row.get_name("status"),
          job: {
            variables,
            dispatch_inputs,
            event,
            outputs: if (row.get_name("definition_version") : Int64) >= 4L {
              job.outputs
            } else {
              Map([])
            },
            needs: if (row.get_name("definition_version") : Int64) >= 4L {
              job_needs_context(tx, (row.get_name("run_id") : Int64), job)
            } else {
              Map([])
            },
            context,
            contents_read: job.contents_read,
            id_token_write: (row.get_name("definition_version") : Int64) >= 7L &&
            job.id_token_write,
            matrix: job.matrix,
            strategy: job.strategy,
            id: if job.matrix_group.is_empty() {
              job.id
            } else {
              job.matrix_group
            },
            name: job.name,
            runs_on: job.runs_on,
            timeout_minutes: job.timeout_minutes,
            steps: job.steps.map(step => {
              id: step.id,
              name: step.name,
              run: step.run,
              uses: step.uses.unwrap_or(""),
              moonbit_version: step.moonbit_version.unwrap_or(""),
              remote: step.remote,
              inputs: step.inputs,
              templates: step.templates,
              shell: step.shell.unwrap_or(""),
              working_directory: step.working_directory,
              env: step.env,
              env_overrides: step.env_overrides,
              secret_env: step.secret_env,
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
  version : Int32,
  execution_id~ : String = "",
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
  version : Int32,
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
  let last_log_sequence = parse_protocol_int64(
    request.last_log_sequence,
    "invalid last log sequence",
  )
  guard ["success", "failure", "cancelled", "timed_out"].contains(
    request.conclusion,
  ) else {
    raise @domain.BadRequest(message="invalid attempt conclusion")
  }
  self.authenticate_attempt(id, token)
  ignore(self.expire_attempts())
  let payload = if request.outputs.is_empty() {
    (
      {
        "version": request.version,
        "conclusion": request.conclusion,
        "last_log_sequence": request.last_log_sequence,
      } : Json)
  } else {
    // JSON object order is not part of a completion's meaning. Canonicalize
    // output entries so a transport can reorder keys during an exact replay.
    let outputs = request.outputs.to_array()
    outputs.sort_by((a, b) => a.0.compare(b.0))
    (
      {
        "version": request.version,
        "conclusion": request.conclusion,
        "last_log_sequence": request.last_log_sequence,
        "outputs": ToJson::to_json(outputs),
      } : Json)
  }
  let hash = @identity.hash_token(payload.stringify())
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
        guard (row.get_name("log_sequence") : Int64) == last_log_sequence else {
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
              if (row.get_name("definition_version") : Int64) >= 2L {
                "SELECT step_id FROM pipeline_step WHERE attempt_id = ? AND state NOT IN ('success', 'skipped') LIMIT 1"
              } else {
                "SELECT step_id FROM pipeline_step WHERE attempt_id = ? AND state <> 'success' LIMIT 1"
              },
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
        publish_job_outputs(tx, row, request.outputs, conclusion)
        finish_attempt(tx, row, conclusion, (self.clock)())
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
