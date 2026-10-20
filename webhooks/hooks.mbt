///|
pub let event_kinds : Array[String] = [
  "push", "issue", "merge_request", "review", "workflow_run", "ping",
]

///|
pub(all) struct Hook {
  id : Int64
  url : String
  events : String
  active : Bool
  version : Int64
}

///|
pub struct Delivery {
  id : Int64
  event_id : Int64
  kind : String
  status : String
  attempts : Int64
  response_code : Int64
  error : String
  created_at : String
  next_attempt_at : String
}

///|
pub fn require_manager(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> @repository.RepositoryScope raise {
  let scope = @repository.repository_scope(pool, actor, repo)
  @repository.authorize_repository(pool, actor, repo, Write)
  guard @identity.can_manage_team(pool, actor, scope.team_id) else {
    raise @domain.Forbidden(message="repository owner or admin required")
  }
  scope
}

///|
fn hook_row(row : @database.DbRow) -> Hook raise {
  {
    id: row.get_name("id"),
    url: row.get_name("url"),
    events: row.get_name("events"),
    active: row.get_name("active"),
    version: row.get_name("version"),
  }
}

///|
pub fn list_hooks(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> Array[Hook] raise {
  let scope = require_manager(pool, actor, repo)
  pool.with_client(client => {
    client
    .query_all(
      "SELECT id,url,events,active,version FROM repository_webhook WHERE repository_id=? ORDER BY id",
      params=[scope.id],
    )
    .map(hook_row)
  })
}

///|
pub fn get_hook(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
) -> Hook raise {
  guard list_hooks(pool, actor, repo).iter().find_first(h => h.id == id)
    is Some(hook) else {
    raise @domain.NotFound(message="webhook not found")
  }
  hook
}

///|
pub fn save_hook(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
  expected : Int64,
  url : String,
  secret : String,
  events : Array[String],
  active : Bool,
  policy : Policy,
) -> Int64 raise {
  let scope = require_manager(pool, actor, repo)
  ignore(parse_target(url, policy))
  guard !events.is_empty() &&
    events.length() <= event_kinds.length() &&
    events.all(kind => event_kinds.contains(kind)) else {
    raise @domain.BadRequest(
      message="select at least one supported webhook event",
    )
  }
  guard (id != 0L && secret.is_empty()) ||
    (
      secret.length() >= 16 &&
      secret.length() <= 256 &&
      secret.iter().all(ch => ch.to_int() >= 33 && ch.to_int() <= 126)
    ) else {
    raise @domain.BadRequest(
      message="signing secret must be 16-256 printable ASCII characters without spaces",
    )
  }
  let selected = event_kinds.filter(kind => events.contains(kind)).join(",")
  pool.with_client(client => {
    client.with_transaction(tx => {
      let hook_id = if id == 0L {
        guard (
            tx
            .query_one(
              "SELECT COUNT(*) AS count FROM repository_webhook WHERE repository_id=?",
              params=[scope.id],
            )
            .get_name("count") : Int64) <
          20L else {
          raise @domain.BadRequest(message="at most 20 webhooks per repository")
        }
        (
          tx
          .query_one(
            "INSERT INTO repository_webhook(repository_id,creator_id,url,secret,events,active) VALUES(?,?,?,?,?,?) RETURNING id",
            params=[scope.id, actor.id, url, secret, selected, active],
          )
          .get_name("id") : Int64)
      } else {
        let changed = tx.execute(
          "UPDATE repository_webhook SET creator_id=?,url=?,secret=CASE WHEN ?='' THEN secret ELSE ? END,events=?,active=?,version=version+1 WHERE id=? AND repository_id=? AND version=?",
          params=[
            actor.id,
            url,
            secret,
            secret,
            selected,
            active,
            id,
            scope.id,
            expected,
          ],
        )
        guard changed == 1 else {
          raise @domain.BadRequest(
            message="webhook changed or was removed; reload before saving",
          )
        }
        ignore(
          tx.execute(
            "UPDATE webhook_delivery SET status='cancelled',lease=NULL,locked_at=NULL,last_error='Webhook configuration changed',completed_at=datetime('now') WHERE webhook_id=? AND status IN ('pending','sending')",
            params=[id],
          ),
        )
        id
      }
      ignore(
        tx.execute(
          "INSERT INTO repository_audit(repository_id,actor_id,kind,detail) VALUES(?,?,'webhook_saved',?)",
          params=[scope.id, actor.id, hook_id.to_string()],
        ),
      )
      hook_id
    })
  })
}

///|
pub fn delete_hook(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
  expected : Int64,
) -> Unit raise {
  let scope = require_manager(pool, actor, repo)
  pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.execute(
          "DELETE FROM repository_webhook WHERE id=? AND repository_id=? AND version=?",
          params=[id, scope.id, expected],
        ) ==
        1 else {
        raise @domain.BadRequest(
          message="webhook changed or was removed; reload before deleting",
        )
      }
      ignore(
        tx.execute(
          "INSERT INTO repository_audit(repository_id,actor_id,kind,detail) VALUES(?,?,'webhook_deleted',?)",
          params=[scope.id, actor.id, id.to_string()],
        ),
      )
    })
  })
}

///|
pub fn deliveries(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  hook_id : Int64,
  page~ : Int64 = 1L,
) -> Array[Delivery] raise {
  ignore(get_hook(pool, actor, repo, hook_id))
  guard page >= 1L && page <= 1000000L else {
    raise @domain.BadRequest(message="invalid delivery page")
  }
  pool.with_client(client => {
    client
    .query_all(
      "SELECT d.*,e.kind,e.created_at FROM webhook_delivery d JOIN webhook_event e ON e.id=d.event_id WHERE d.webhook_id=? ORDER BY d.id DESC LIMIT 50 OFFSET ?",
      params=[hook_id, (page - 1L) * 50L],
    )
    .map(row => {
      id: row.get_name("id"),
      event_id: row.get_name("event_id"),
      kind: row.get_name("kind"),
      status: row.get_name("status"),
      attempts: row.get_name("attempts"),
      response_code: row.get_name("response_code"),
      error: row.get_name("last_error"),
      created_at: row.get_name("created_at"),
      next_attempt_at: row.get_name("next_attempt_at"),
    })
  })
}

///|
pub fn delivery_detail(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  hook_id : Int64,
  id : Int64,
) -> Json raise {
  ignore(get_hook(pool, actor, repo, hook_id))
  pool.with_client(client => {
    guard client.query_opt(
        "SELECT e.payload FROM webhook_delivery d JOIN webhook_event e ON e.id=d.event_id WHERE d.id=? AND d.webhook_id=?",
        params=[id, hook_id],
      )
      is Some(row) else {
      raise @domain.NotFound(message="delivery not found")
    }
    {
      "payload": (row.get_name("payload") : String),
      "attempts": client
      .query_all(
        "SELECT attempt,response_code,error,started_at,completed_at FROM webhook_attempt WHERE delivery_id=? ORDER BY attempt",
        params=[id],
      )
      .map(a => {
        (
          {
            "attempt": (a.get_name("attempt") : Int64).to_string(),
            "response_code": (a.get_name("response_code") : Int64).to_string(),
            "error": (a.get_name("error") : String),
            "started_at": (a.get_name("started_at") : String),
            "completed_at": (a.get_name("completed_at") : String?).unwrap_or(""),
          } : Json)
      }),
    }
  })
}

///|
pub fn redeliver(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  hook_id : Int64,
  id : Int64,
) -> Unit raise {
  let scope = require_manager(pool, actor, repo)
  let hook = get_hook(pool, actor, repo, hook_id)
  guard hook.active else {
    raise @domain.BadRequest(message="enable the webhook before redelivery")
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.execute(
          "UPDATE webhook_delivery SET status='pending',max_attempts=attempts+5,next_attempt_at=datetime('now'),last_error='',completed_at=NULL WHERE id=? AND webhook_id=? AND status IN ('failed','succeeded','cancelled')",
          params=[id, hook_id],
        ) ==
        1 else {
        raise @domain.BadRequest(
          message="delivery is pending, sending or missing",
        )
      }
      ignore(
        tx.execute(
          "INSERT INTO repository_audit(repository_id,actor_id,kind,detail) VALUES(?,?,'webhook_redeliver',?)",
          params=[scope.id, actor.id, id.to_string()],
        ),
      )
    })
  })
}

///|
pub fn ping(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
) -> Unit raise {
  let scope = require_manager(pool, actor, repo)
  let hook = get_hook(pool, actor, repo, id)
  guard hook.active else {
    raise @domain.BadRequest(message="enable the webhook before sending a test")
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      let event_id : Int64 = tx
        .query_one(
          "INSERT INTO webhook_event(repository_id,event_key,kind,payload) VALUES(?,?,'ping',?) RETURNING id",
          params=[
            scope.id,
            "ping:" + @identity.random_hex(16),
            (
              {
                "schema_version": 1,
                "event": "ping",
                "action": "ping",
                "repository": {
                  "id": scope.id.to_string(),
                  "full_name": repo.path(),
                },
                "sender": {
                  "id": actor.id.to_string(),
                  "username": actor.name_key,
                },
              } : Json).stringify(),
          ],
        )
        .get_name("id")
      // A test is addressed to exactly this hook, independent of its subscriptions.
      ignore(
        tx.execute("DELETE FROM webhook_delivery WHERE event_id=?", params=[
          event_id,
        ]),
      )
      ignore(
        tx.execute(
          "INSERT INTO webhook_delivery(webhook_id,event_id) VALUES(?,?)",
          params=[id, event_id],
        ),
      )
    })
  })
}
