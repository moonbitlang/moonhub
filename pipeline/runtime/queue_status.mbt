///|
#derive(Eq, Debug)
pub enum QueueReason {
  WaitingDependencies
  WaitingApproval
  WaitingConcurrency
  WaitingMatrixCapacity
  RequesterUnavailable
  NoAuthorizedProvider
  RunnerGroupUnavailable
  NoMatchingLabels
  EnvironmentUnavailable
  ProvidersPaused
  ProvidersBusy
  NoRecentProviderContact
  AwaitingClaim
}

///|
pub fn Coordinator::queue_reasons(
  self : Coordinator,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
) -> Map[String, QueueReason] raise {
  let run = get_run(self.pool, actor, repo, number)
  let now = (self.clock)()
  self.pool.with_client(client => {
    let result : Map[String, QueueReason] = Map([])
    let eligible = client.query_opt(
        "SELECT repo.id FROM repository repo JOIN \"user\" u ON u.id = ? LEFT JOIN team_member tm ON tm.team_id = repo.team_id AND tm.user_id = u.id WHERE repo.id = ? AND repo.ready = 1 AND u.status = 'active' AND (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin'))",
        params=[run.requested_by_user_id, run.repository_id],
      )
      is Some(_)
    for
      job in client.query_all(
        "SELECT id, job_key, status FROM pipeline_job WHERE run_id = ? AND status IN ('waiting', 'queued') ORDER BY ordinal",
        params=[run.id],
      ) {
      let key : String = job.get_name("job_key")
      if client.query_opt(
          "SELECT job_id FROM pipeline_job_deployment WHERE job_id=? AND state='pending'",
          params=[(job.get_name("id") : Int64)],
        )
        is Some(_) {
        result[key] = WaitingApproval
        continue
      }
      if client.query_opt(
          "SELECT id FROM pipeline_concurrency_slot WHERE run_id=? AND (job_id IS NULL OR job_id=?) AND admitted=0",
          params=[run.id, (job.get_name("id") : Int64)],
        )
        is Some(_) {
        result[key] = WaitingConcurrency
        continue
      }
      if client.query_opt(
          "SELECT j.id FROM pipeline_job j WHERE j.id=? AND j.matrix_group <> '' AND (SELECT COUNT(*) FROM pipeline_job s WHERE s.run_id=j.run_id AND s.matrix_group=j.matrix_group AND s.status IN ('leased','running')) >= j.max_parallel",
          params=[(job.get_name("id") : Int64)],
        )
        is Some(_) {
        result[key] = WaitingMatrixCapacity
        continue
      }
      if (job.get_name("status") : String) == "waiting" {
        result[key] = WaitingDependencies
        continue
      }
      if !eligible {
        result[key] = RequesterUnavailable
        continue
      }
      let job_id : Int64 = job.get_name("id")
      if client.query_opt(
          "SELECT job_id FROM pipeline_job_runner_group WHERE job_id=?",
          params=[job_id],
        )
        is Some(_) &&
        client.query_opt(
          "SELECT job_id FROM pipeline_provider_job_group WHERE job_id=?",
          params=[job_id],
        )
        is None {
        result[key] = RunnerGroupUnavailable
        continue
      }
      // Expose aggregate blockers, never provider identities or other grants.
      let candidates = client.query_all(
        (
          #|SELECT p.paused, p.last_seen_ms,
          #|EXISTS (SELECT 1 FROM pipeline_provider_job_environment candidate
          #|  WHERE candidate.job_id=? AND candidate.provider_id=p.id) AS matches_labels,
          #|EXISTS (SELECT 1 FROM pipeline_job_attempt a WHERE a.provider_id=p.id AND a.status<>'completed')
          #|AND (p.mode='' OR NOT EXISTS (SELECT 1 FROM pipeline_worker w WHERE w.provider_id=p.id
          #|  AND w.state='ready' AND w.draining=0 AND w.applied_revision=p.config_revision
          #|  AND w.last_seen_ms>CAST(strftime('%s','now') AS INTEGER)*1000-180000)) AS busy
          #|FROM pipeline_provider p WHERE p.revoked = 0 AND (p.repository_scope = 'all'
          #|  OR EXISTS (SELECT 1 FROM pipeline_provider_repository g WHERE g.provider_id = p.id AND g.repository_id = ?))
        ),
        params=[job_id, run.repository_id],
      )
      let matching = candidates.filter(row => {
        (row.get_name("matches_labels") : Bool)
      })
      let active = matching.filter(row => !(row.get_name("paused") : Bool))
      let idle = active.filter(row => !(row.get_name("busy") : Bool))
      result[key] = if candidates.is_empty() {
        NoAuthorizedProvider
      } else if matching.is_empty() {
        if client.query_opt(
            "SELECT job_id FROM pipeline_job_environment WHERE job_id=?",
            params=[job_id],
          )
          is Some(_) {
          EnvironmentUnavailable
        } else {
          NoMatchingLabels
        }
      } else if active.is_empty() {
        ProvidersPaused
      } else if idle.is_empty() {
        ProvidersBusy
      } else if !idle.any(row => {
          (row.get_name("last_seen_ms") : Int64?) is Some(seen) &&
          seen <= now &&
          now - seen < provider_contact_window_ms
        }) {
        NoRecentProviderContact
      } else {
        AwaitingClaim
      }
    }
    result
  })
}
