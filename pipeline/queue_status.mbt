///|
#derive(Eq, Debug)
pub enum QueueReason {
  WaitingDependencies
  RequesterUnavailable
  NoAuthorizedProvider
  NoMatchingLabels
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
      if (job.get_name("status") : String) == "waiting" {
        result[key] = WaitingDependencies
        continue
      }
      if !eligible {
        result[key] = RequesterUnavailable
        continue
      }
      let job_id : Int64 = job.get_name("id")
      // Expose aggregate blockers, never provider identities or other grants.
      let candidates = client.query_all(
        (
          #|SELECT p.paused, p.last_seen_ms,
          #|NOT EXISTS (SELECT 1 FROM pipeline_job_label required WHERE required.job_id = ?
          #|  AND NOT EXISTS (SELECT 1 FROM pipeline_provider_label label WHERE label.provider_id = p.id AND label.label = required.label)) AS matches_labels,
          #|EXISTS (SELECT 1 FROM pipeline_job_attempt a WHERE a.provider_id = p.id AND a.status <> 'completed') AS busy
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
        NoMatchingLabels
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
