///|
// Shared by claims and capacity demand. An environment owns one provider per
// profile, so its queued job can never inflate both groups' desired capacity.
let execution_route_eligibility : String =
  #|AND (NOT EXISTS (SELECT 1 FROM pipeline_job_execution x WHERE x.job_id=j.id)
  #| OR EXISTS (SELECT 1 FROM pipeline_job_execution x
  #| JOIN pipeline_execution_environment e ON e.id=x.environment_id
  #| WHERE x.job_id=j.id AND x.environment_version=e.environment_version
  #| AND x.cleanup_worker_id IS NULL
  #| AND provider.id=CASE x.profile WHEN 'linux-ci' THEN e.linux_ci_provider_id ELSE e.restricted_provider_id END
  #| AND ((x.profile='linux-ci' AND provider.mode='asg' AND json_extract(provider.config_json,'$.execution_mode')='linux-ci')
  #| OR (x.profile='restricted' AND provider.mode IN ('asg','docker') AND COALESCE(json_extract(provider.config_json,'$.execution_mode'),'')<>'linux-ci'))))

///|
fn execution_assignment(
  tx : @database.DbTransaction,
  row : @database.DbRow,
) -> @protocol.ExecutionContext? raise {
  tx
  .query_opt(
    "SELECT x.*,e.name environment FROM pipeline_job_execution x JOIN pipeline_execution_environment e ON e.id=x.environment_id WHERE x.job_id=?",
    params=[(row.get_name("job_id") : Int64)],
  )
  .map(x => {
    environment: x.get_name("environment"),
    environment_version: x.get_name("environment_version"),
    profile: x.get_name("profile"),
    probe_capabilities: (x.get_name("profile") : String) == "restricted",
  })
}

///|
fn record_execution_attempt(
  tx : @database.DbTransaction,
  id : Int64,
  provider : @database.DbRow,
) -> Unit raise {
  ignore(
    tx.execute(
      "UPDATE pipeline_job_attempt SET deadline_ms=(SELECT deadline_ms FROM pipeline_job_execution WHERE job_id=pipeline_job_attempt.job_id),lease_until_ms=MIN(lease_until_ms,COALESCE((SELECT deadline_ms FROM pipeline_job_execution WHERE job_id=pipeline_job_attempt.job_id),lease_until_ms)) WHERE id=?",
      params=[id],
    ),
  )
  let config : Map[String, String] = @json.from_json(
    @json.parse((provider.get_name("config_json") : String)),
  )
  ignore(
    tx.execute(
      "INSERT INTO pipeline_attempt_execution(attempt_id,profile,reason,purchase_policy) SELECT ?,x.profile,x.reason,? FROM pipeline_job_execution x JOIN pipeline_job_attempt a ON a.job_id=x.job_id WHERE a.id=?",
      params=[id, config.get("purchase_policy").unwrap_or("on-demand"), id],
    ),
  )
}

///|
fn learn_execution_requirement(
  tx : @database.DbTransaction,
  row : @database.DbRow,
  capability : String,
  now : Int64,
) -> Bool raise {
  let id : Int64 = row.get_name("id")
  let job : Int64 = row.get_name("job_id")
  let x = tx.query_opt(
    "SELECT x.*,e.environment_version current_version,e.linux_ci_provider_id FROM pipeline_job_execution x JOIN pipeline_execution_environment e ON e.id=x.environment_id JOIN pipeline_attempt_execution a ON a.attempt_id=? WHERE x.job_id=? AND a.profile='restricted'",
    params=[id, job],
  )
  guard x is Some(x) else {
    raise @domain.BadRequest(
      message="Capability reports require a restricted execution assignment.",
    )
  }
  let repo : Int64 = row.get_name("repository_id")
  let key : String = x.get_name("learning_key")
  let trust : String = x.get_name("trust_scope")
  // Cache is a bounded scheduling hint, scoped by repository and captured ref.
  // Reports never authorize providers or alter an already running assignment.
  ignore(
    tx.execute(
      "INSERT INTO pipeline_execution_learning(repository_id,learning_key,trust_scope,capability,updated_ms) VALUES(?,?,?,?,?) ON CONFLICT(repository_id,learning_key,trust_scope,capability) DO UPDATE SET updated_ms=excluded.updated_ms",
      params=[repo, key, trust, capability, now],
    ),
  )
  ignore(
    tx.execute(
      "DELETE FROM pipeline_execution_learning WHERE repository_id=? AND rowid NOT IN (SELECT rowid FROM pipeline_execution_learning WHERE repository_id=? ORDER BY updated_ms DESC,rowid DESC LIMIT 2048)",
      params=[repo, repo],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_attempt_execution SET failure_kind='missing_capability',missing_capability=? WHERE attempt_id=?",
      params=[capability, id],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job_execution SET profile='linux-ci',reason='learned_requirement' WHERE job_id IN (SELECT j.id FROM pipeline_job j JOIN pipeline_run r ON r.id=j.run_id WHERE r.repository_id=? AND j.status IN ('waiting','queued')) AND learning_key=? AND trust_scope=? AND cleanup_worker_id IS NULL AND routing='adaptive'",
      params=[repo, key, trust],
    ),
  )
  guard (x.get_name("routing") : String) == "adaptive" &&
    (x.get_name("retry_allowed") : Bool) &&
    !(x.get_name("retry_used") : Bool) &&
    (x.get_name("environment_version") : String) ==
    (x.get_name("current_version") : String) &&
    (row.get_name("worker_id") : Int64?) is Some(worker) &&
    (row.get_name("cancel_at_ms") : Int64?) is None &&
    !(row.get_name("cancel_requested") : Bool) &&
    (x.get_name("deadline_ms") : Int64?) is Some(deadline) &&
    deadline > now &&
    attempt_authorized(tx, row) else {
    return false
  }
  let target : Int64? = x.get_name("linux_ci_provider_id")
  guard target is Some(target) else { return false }
  // Fallback still needs an existing, unpaused and repository-authorized CI
  // provider. A worker report cannot turn credentials into privileged access.
  guard tx.query_opt(
      "SELECT p.id FROM pipeline_provider p WHERE p.id=? AND p.revoked=0 AND p.paused=0 AND p.mode='asg' AND json_extract(p.config_json,'$.execution_mode')='linux-ci' AND (p.repository_scope='all' OR EXISTS(SELECT 1 FROM pipeline_provider_repository g WHERE g.provider_id=p.id AND g.repository_id=?)) AND NOT EXISTS(SELECT 1 FROM pipeline_job_label l WHERE l.job_id=? AND NOT EXISTS(SELECT 1 FROM pipeline_provider_label pl WHERE pl.provider_id=p.id AND pl.label=l.label))",
      params=[target, repo, job],
    )
    is Some(_) else {
    return false
  }
  ignore(
    tx.execute(
      "UPDATE pipeline_job_execution SET profile='linux-ci',reason='capability_fallback',retry_used=1,cleanup_worker_id=?,cleanup_until_ms=? WHERE job_id=?",
      params=[worker, Int64::min(deadline, now + 120000L), job],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_cache SET state='deleted' WHERE artifact_id IN (SELECT id FROM pipeline_artifact WHERE attempt_id=?)",
      params=[id],
    ),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_artifact SET state='deleted' WHERE attempt_id=?",
      params=[id],
    ),
  )
  true
}

///|
pub fn Coordinator::execution_cleanup(
  self : Coordinator,
  worker_token : String,
  attempt : Int64,
) -> Unit raise {
  self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        let worker = authenticate_worker(tx, worker_token)
        expire_execution_jobs(tx, (self.clock)())
        let wid : Int64 = worker.get_name("id")
        guard tx.query_opt(
            "SELECT a.id FROM pipeline_job_attempt a JOIN pipeline_job_execution x ON x.job_id=a.job_id WHERE a.id=? AND a.worker_id=? AND a.status='completed' AND x.cleanup_worker_id=? AND a.id=(SELECT MAX(last.id) FROM pipeline_job_attempt last WHERE last.job_id=a.job_id)",
            params=[attempt, wid, wid],
          )
          is Some(_) else {
          // A replay after a committed acknowledgement is safe, including after
          // the replacement attempt was claimed on a different provider.
          guard tx.query_opt(
              "SELECT a.id FROM pipeline_job_attempt a JOIN pipeline_attempt_execution x ON x.attempt_id=a.id WHERE a.id=? AND a.worker_id=? AND a.status='completed' ",
              params=[attempt, wid],
            )
            is Some(_) else {
            raise Conflict(
              "No completed execution awaits this worker's cleanup.",
            )
          }
          return
        }
        ignore(
          tx.execute(
            "UPDATE pipeline_job_execution SET cleanup_worker_id=NULL,cleanup_until_ms=NULL WHERE cleanup_worker_id=? AND job_id=(SELECT job_id FROM pipeline_job_attempt WHERE id=?)",
            params=[wid, attempt],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
fn expire_execution_jobs(
  tx : @database.DbTransaction,
  now : Int64,
) -> Unit raise {
  let rows = tx.query_all(
    "SELECT j.id,j.run_id,x.deadline_ms FROM pipeline_job_execution x JOIN pipeline_job j ON j.id=x.job_id JOIN pipeline_execution_environment e ON e.id=x.environment_id WHERE j.status IN ('waiting','queued') AND ((x.deadline_ms IS NOT NULL AND x.deadline_ms<=?) OR (x.cleanup_until_ms IS NOT NULL AND x.cleanup_until_ms<=?) OR e.environment_version<>x.environment_version) ORDER BY j.id LIMIT 100",
    params=[now, now],
  )
  for r in rows {
    let id : Int64 = r.get_name("id")
    let deadline : Int64? = r.get_name("deadline_ms")
    let conclusion = if deadline is Some(d) && d <= now {
      "timed_out"
    } else {
      "failure"
    }
    guard tx.execute(
        "UPDATE pipeline_job SET status='completed',conclusion=? WHERE id=? AND status IN ('waiting','queued')",
        params=[conclusion, id],
      ) ==
      1 else {
      continue
    }
    cancel_matrix_siblings(tx, id, conclusion, now)
    let run : Int64 = r.get_name("run_id")
    advance_run_jobs(tx, run)
    finalize_run(tx, run)
  }
}

///|
pub fn execution_history(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
) -> Json raise {
  let run = get_run(pool, actor, repo, number)
  pool.with_client(c => {
    let jobs = c.query_all(
      "SELECT j.job_key,j.status,e.name environment,x.environment_version,x.profile,x.reason,x.retry_used,x.cleanup_worker_id FROM pipeline_job_execution x JOIN pipeline_job j ON j.id=x.job_id JOIN pipeline_execution_environment e ON e.id=x.environment_id WHERE j.run_id=? ORDER BY j.ordinal",
      params=[run.id],
    )
    let rows = c.query_all(
      "SELECT a.id,a.number,a.status,a.conclusion,j.job_key,p.name provider,x.* FROM pipeline_job_attempt a JOIN pipeline_job j ON j.id=a.job_id LEFT JOIN pipeline_provider p ON p.id=a.provider_id LEFT JOIN pipeline_attempt_execution x ON x.attempt_id=a.id WHERE j.run_id=? ORDER BY j.ordinal,a.number",
      params=[run.id],
    )
    {
      "jobs": jobs.map(j => {
        (
          {
            "job": (j.get_name("job_key") : String),
            "status": (j.get_name("status") : String),
            "environment": (j.get_name("environment") : String),
            "environment_version": (j.get_name("environment_version") : String),
            "profile": (j.get_name("profile") : String),
            "reason": (j.get_name("reason") : String),
            "retry_used": (j.get_name("retry_used") : Bool),
            "awaiting_cleanup": (j.get_name("cleanup_worker_id") : Int64?)
            is Some(_),
          } : Json)
      }),
      "attempts": rows.map(r => {
        (
          {
            "attempt": (r.get_name("id") : Int64).to_string(),
            "number": (r.get_name("number") : Int64).to_string(),
            "job": (r.get_name("job_key") : String),
            "status": (r.get_name("status") : String),
            "conclusion": (r.get_name("conclusion") : String?).unwrap_or(""),
            "provider": (r.get_name("provider") : String?).unwrap_or(""),
            "profile": (r.get_name("profile") : String?).unwrap_or(""),
            "reason": (r.get_name("reason") : String?).unwrap_or(""),
            "purchase_policy": (r.get_name("purchase_policy") : String?).unwrap_or(
              "",
            ),
            "failure_kind": (r.get_name("failure_kind") : String?).unwrap_or(""),
            "missing_capability": (r.get_name("missing_capability") : String?).unwrap_or(
              "",
            ),
          } : Json)
      }),
    }
  })
}
