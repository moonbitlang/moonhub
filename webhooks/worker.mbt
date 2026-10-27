///|
priv struct Assignment {
  id : Int64
  event_id : Int64
  kind : String
  body : String
  url : String
  secret : String
  attempt : Int64
  lease : String
}

///|
fn claim(pool : @database.Database) -> Assignment? raise {
  pool.with_client(client => {
    client.with_transaction(tx => {
      // Restarted/expired attempts remain visible, and can be retried at least once.
      ignore(
        tx.execute(
          "UPDATE webhook_attempt SET completed_at=datetime('now'),error='Delivery lease expired' WHERE completed_at IS NULL AND delivery_id IN (SELECT id FROM webhook_delivery WHERE status='sending' AND locked_at<=datetime('now','-1 minute'))",
        ),
      )
      ignore(
        tx.execute(
          "UPDATE webhook_delivery SET status=CASE WHEN attempts>=max_attempts THEN 'failed' ELSE 'pending' END,completed_at=CASE WHEN attempts>=max_attempts THEN datetime('now') ELSE NULL END,lease=NULL,locked_at=NULL,last_error='Delivery lease expired' WHERE status='sending' AND locked_at<=datetime('now','-1 minute')",
        ),
      )
      ignore(
        tx.execute(
          "UPDATE webhook_delivery SET status='cancelled',last_error='Webhook disabled or owner access revoked',completed_at=datetime('now') WHERE status='pending' AND NOT EXISTS(SELECT 1 FROM repository_webhook h JOIN repository r ON r.id=h.repository_id JOIN team t ON t.id=r.team_id JOIN \"user\" u ON u.id=h.creator_id AND u.status='active' LEFT JOIN team_member m ON m.team_id=t.id AND m.user_id=u.id WHERE h.id=webhook_delivery.webhook_id AND h.active=1 AND r.ready=1 AND (u.is_site_admin=1 OR m.role IN ('owner','admin')))",
        ),
      )
      guard tx.query_opt(
          "SELECT d.id,d.event_id,d.attempts,e.kind,e.payload,h.url,h.secret FROM webhook_delivery d JOIN webhook_event e ON e.id=d.event_id JOIN repository_webhook h ON h.id=d.webhook_id WHERE d.status='pending' AND d.next_attempt_at<=datetime('now') ORDER BY d.next_attempt_at,d.id LIMIT 1",
        )
        is Some(row) else {
        return None
      }
      let id : Int64 = row.get_name("id")
      let attempt = (row.get_name("attempts") : Int64) + 1L
      let lease = @identity.random_hex(16)
      ignore(
        tx.execute(
          "UPDATE webhook_delivery SET status='sending',attempts=?,lease=?,locked_at=datetime('now') WHERE id=?",
          params=[attempt, lease, id],
        ),
      )
      ignore(
        tx.execute(
          "INSERT INTO webhook_attempt(delivery_id,attempt) VALUES(?,?)",
          params=[id, attempt],
        ),
      )
      Some({
        id,
        event_id: row.get_name("event_id"),
        kind: row.get_name("kind"),
        body: row.get_name("payload"),
        url: row.get_name("url"),
        secret: row.get_name("secret"),
        attempt,
        lease,
      })
    })
  })
}

///|
pub async fn deliver_next(pool : @database.Database, policy : Policy) -> Bool {
  guard claim(pool) is Some(job) else { return false }
  let code = @async.with_timeout(
    10000,
    () => {
      send_delivery(
        parse_target(job.url, policy),
        job.kind,
        job.id,
        job.event_id,
        job.secret,
        job.body,
        () => ensure_current_delivery(pool, job),
      )
    },
    error=Rejected,
  ) catch {
    _ => 0
  }
  let success = code >= 200 && code < 300
  let error = if success {
    ""
  } else if code == 0 {
    "Connection, TLS, destination policy, timeout or response error"
  } else {
    "HTTP \{code}; redirects are not followed"
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      ignore(
        tx.execute(
          "UPDATE webhook_attempt SET response_code=?,error=?,completed_at=datetime('now') WHERE delivery_id=? AND attempt=? AND completed_at IS NULL",
          params=[code.to_int64(), error, job.id, job.attempt],
        ),
      )
      // Each budget contains five attempts; remaining budget identifies this
      // retry cycle without resetting the cumulative attempt/history identity.
      ignore(
        tx.execute(
          "UPDATE webhook_delivery SET status=CASE WHEN ? THEN 'succeeded' WHEN attempts>=max_attempts THEN 'failed' ELSE 'pending' END,response_code=?,last_error=?,lease=NULL,locked_at=NULL,next_attempt_at=datetime('now','+' || CASE max_attempts-attempts WHEN 4 THEN 10 WHEN 3 THEN 60 WHEN 2 THEN 300 ELSE 1800 END || ' seconds'),completed_at=CASE WHEN ? OR attempts>=max_attempts THEN datetime('now') ELSE NULL END WHERE id=? AND status='sending' AND lease=?",
          params=[success, code.to_int64(), error, success, job.id, job.lease],
        ),
      )
    })
  })
  true
}

///|
pub fn start_worker(
  pool : @database.Database,
  root : String,
  policy : Policy,
  group : @async.TaskGroup[Unit],
) -> Unit {
  group.spawn_bg(no_wait=true, allow_failure=true, () => {
    let mut recovery_after = 0L
    for ;; {
      let processed = try {
        recovery_after = recover_refs(pool, root, after=recovery_after)
        deliver_next(pool, policy)
      } catch {
        _ => {
          println("webhook worker could not process an event; retrying")
          false
        }
      }
      if !processed {
        @async.sleep(1000)
      }
    }
  })
}

///|
// DNS and TLS may yield after claiming; recheck immediately before sending data.
fn ensure_current_delivery(
  pool : @database.Database,
  job : Assignment,
) -> Unit raise {
  pool.with_client(client => {
    guard client.query_opt(
        "SELECT d.id FROM webhook_delivery d JOIN repository_webhook h ON h.id=d.webhook_id JOIN repository r ON r.id=h.repository_id JOIN \"user\" u ON u.id=h.creator_id AND u.status='active' LEFT JOIN team_member m ON m.team_id=r.team_id AND m.user_id=u.id WHERE d.id=? AND d.lease=? AND d.status='sending' AND h.active=1 AND r.ready=1 AND (u.is_site_admin=1 OR m.role IN ('owner','admin'))",
        params=[job.id, job.lease],
      )
      is Some(_) else {
      raise Rejected
    }
  })
}
