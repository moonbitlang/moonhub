///|
pub struct ProviderControl {
  snapshot : @protocol.ProviderSnapshot
  observed_revision : Int64
  applied_revision : Int64
  status : String
}

///|
fn worker_views(
  tx : @database.DbTransaction,
  provider_id : Int64,
) -> Array[@protocol.WorkerView] raise {
  tx
  .query_all(
    "SELECT w.*, (SELECT count(*) FROM pipeline_job_attempt a WHERE a.worker_id=w.id AND a.status<>'completed') AS active FROM pipeline_worker w WHERE w.provider_id=? AND (w.state NOT IN ('drained','failed') OR EXISTS (SELECT 1 FROM pipeline_job_attempt a WHERE a.worker_id=w.id AND a.status<>'completed') OR w.id IN (SELECT id FROM pipeline_worker WHERE provider_id=? ORDER BY id DESC LIMIT 100)) ORDER BY w.id",
    params=[provider_id, provider_id],
  )
  .map(worker_view)
}

///|
fn worker_view(row : @database.DbRow) -> @protocol.WorkerView raise {
  {
    id: (row.get_name("id") : Int64).to_string(),
    key: row.get_name("worker_key"),
    state: row.get_name("state"),
    draining: row.get_name("draining"),
    applied_revision: (row.get_name("applied_revision") : Int64).to_string(),
    last_seen_ms: (row.get_name("last_seen_ms") : Int64).to_string(),
    idle_since_ms: (row.get_name("idle_since_ms") : Int64).to_string(),
    active_attempts: (row.get_name("active") : Int64).to_int(),
  }
}

///|
fn control_snapshot(
  tx : @database.DbTransaction,
  row : @database.DbRow,
) -> @protocol.ProviderSnapshot raise {
  let id : Int64 = row.get_name("id")
  let paused : Bool = row.get_name("paused")
  let queued : Int64 = if paused {
    0L
  } else {
    tx
    .query_one("SELECT count(*) AS count FROM (\{eligible_provider_jobs})", params=[
      id,
      @workflow.format_version.to_int64(),
      id,
    ])
    .get_name("count")
  }
  {
    version: 1,
    id: id.to_string(),
    mode: row.get_name("mode"),
    paused,
    config_revision: (row.get_name("config_revision") : Int64).to_string(),
    schema: @json.from_json(
      @json.parse((row.get_name("config_schema") : String)),
    ),
    config: @json.from_json(@json.parse((row.get_name("config_json") : String))),
    queued_jobs: queued.to_int(),
    workers: worker_views(tx, id),
  }
}

///|
pub fn Coordinator::register_runner(
  self : Coordinator,
  registration_token : String,
  request : @protocol.RegisterProviderRequest,
) -> @protocol.ProviderSnapshot raise {
  check_version(request.version)
  check_token(registration_token)
  check_token(request.provider_token)
  guard @domain.valid_segment(request.mode) &&
    request.mode.length() <= 32 &&
    @domain.valid_segment(request.name) else {
    raise @domain.BadRequest(message="Invalid provider mode or name.")
  }
  guard registration_token != request.provider_token else {
    raise @domain.BadRequest(
      message="Registration and provider credentials must differ.",
    )
  }
  if @protocol.validate_config(request.schema, request.defaults)
    is Some(message) {
    raise @domain.BadRequest(message~)
  }
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let hash = @identity.hash_token(registration_token)
        let credential_hash = @identity.hash_token(request.provider_token)
        let row = tx.query_opt(
          "SELECT * FROM pipeline_provider WHERE name=? AND (token_hash=? OR registration_hash=?) AND revoked=0",
          params=[request.name, hash, hash],
        )
        guard row is Some(row) else {
          raise @domain.Unauthorized(message="Invalid provider registration.")
        }
        let id : Int64 = row.get_name("id")
        let mode : String = row.get_name("mode")
        if !mode.is_empty() {
          guard mode == request.mode &&
            (row.get_name("token_hash") : String) == credential_hash &&
            (row.get_name("config_schema") : String) ==
            ToJson::to_json(request.schema).stringify() else {
            raise Conflict(
              "Provider already registered with another identity, mode or schema.",
            )
          }
          return control_snapshot(tx, row)
        }
        guard tx.query_opt(
            "SELECT id FROM pipeline_provider WHERE token_hash=? OR registration_hash=? UNION SELECT id FROM pipeline_worker WHERE token_hash=? UNION SELECT id FROM pipeline_job_attempt WHERE token_hash=?",
            params=[
              credential_hash, credential_hash, credential_hash, credential_hash,
            ],
          )
          is None else {
          raise Conflict("Credential already in use.")
        }
        guard tx.query_opt(
            "SELECT id FROM pipeline_job_attempt WHERE provider_id=? AND status<>'completed'",
            params=[id],
          )
          is None else {
          raise Conflict("Drain the legacy provider before registration.")
        }
        ignore(
          tx.execute(
            "UPDATE pipeline_provider SET mode=?,registration_hash=?,token_hash=?,config_schema=?,config_json=?,config_revision=1,control_status='pending' WHERE id=?",
            params=[
              request.mode,
              hash,
              credential_hash,
              ToJson::to_json(request.schema).stringify(),
              ToJson::to_json(request.defaults).stringify(),
              id,
            ],
          ),
        )
        control_snapshot(
          tx,
          tx.query_one("SELECT * FROM pipeline_provider WHERE id=?", params=[id]),
        )
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::provider_control(
  self : Coordinator,
  actor : @domain.CurrentUser,
  id : Int64,
) -> ProviderControl raise {
  require_provider_admin(self.pool, actor)
  self.pool.with_client(client => {
    client.with_transaction(tx => {
      let row = tx.query_opt(
        "SELECT * FROM pipeline_provider WHERE id=? AND revoked=0",
        params=[id],
      )
      guard row is Some(row) else {
        raise @domain.NotFound(message="Provider not found.")
      }
      {
        snapshot: control_snapshot(tx, row),
        observed_revision: row.get_name("observed_revision"),
        applied_revision: row.get_name("applied_revision"),
        status: row.get_name("control_status"),
      }
    })
  })
}

///|
pub fn Coordinator::save_provider_config(
  self : Coordinator,
  actor : @domain.CurrentUser,
  id : Int64,
  revision : Int64,
  config : Map[String, String],
) -> Unit raise {
  require_provider_admin(self.pool, actor)
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = tx.query_opt(
          "SELECT * FROM pipeline_provider WHERE id=? AND revoked=0",
          params=[id],
        )
        guard row is Some(row) else {
          raise @domain.NotFound(message="Provider not found.")
        }
        guard !(row.get_name("mode") : String).is_empty() else {
          raise @domain.BadRequest(
            message="Connect moonhub-runner before editing execution settings.",
          )
        }
        guard (row.get_name("config_revision") : Int64) == revision else {
          raise Conflict("Configuration changed. Reload before saving.")
        }
        let schema : Array[@protocol.ConfigField] = @json.from_json(
          @json.parse((row.get_name("config_schema") : String)),
        )
        if @protocol.validate_config(schema, config) is Some(message) {
          raise @domain.BadRequest(message~)
        }
        ignore(
          tx.execute(
            "UPDATE pipeline_provider SET config_json=?,config_revision=config_revision+1,control_status='pending' WHERE id=?",
            params=[ToJson::to_json(config).stringify(), id],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::sync_provider(
  self : Coordinator,
  token : String,
  request : @protocol.ProviderSyncRequest,
) -> @protocol.ProviderSnapshot raise {
  check_version(request.version)
  guard @domain.valid_segment(request.controller_id) &&
    request.controller_id.length() <= 64 &&
    ["pending", "applied", "failed", "replacing"].contains(request.status) else {
    raise @domain.BadRequest(message="Invalid controller state.")
  }
  let observed = parse_protocol_int64(
    request.observed_revision,
    "Invalid observed revision.",
  )
  let applied = parse_protocol_int64(
    request.applied_revision,
    "Invalid applied revision.",
  )
  ignore(self.expire_attempts())
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = authenticate_provider(tx, token)
        let id : Int64 = row.get_name("id")
        let registered_revision : Int64 = row.get_name("config_revision")
        let now = (self.clock)()
        guard !(row.get_name("mode") : String).is_empty() &&
          applied <= observed &&
          observed <= registered_revision else {
          raise @domain.BadRequest(
            message="Invalid configuration acknowledgement.",
          )
        }
        let owner : String? = row.get_name("controller_id")
        guard owner is None ||
          owner == Some(request.controller_id) ||
          (row.get_name("controller_until_ms") : Int64) <= now else {
          raise Conflict("Another controller holds this provider lease.")
        }
        match (request.schema, request.defaults) {
          (Some(schema), Some(defaults)) => {
            if @protocol.validate_config(schema, defaults) is Some(message) {
              raise @domain.BadRequest(message~)
            }
            let old_schema : Array[@protocol.ConfigField] = @json.from_json(
              @json.parse((row.get_name("config_schema") : String)),
            )
            guard old_schema.length() <= schema.length() else {
              raise Conflict(
                "Controller schema can only append configuration fields.",
              )
            }
            for i in 0..<old_schema.length() {
              guard ToJson::to_json(old_schema[i]).stringify() ==
                ToJson::to_json(schema[i]).stringify() else {
                raise Conflict(
                  "Controller schema can only append configuration fields.",
                )
              }
            }
            if old_schema.length() < schema.length() {
              let config : Map[String, String] = @json.from_json(
                @json.parse((row.get_name("config_json") : String)),
              )
              for i in old_schema.length()..<schema.length() {
                let field = schema[i]
                config[field.name] = defaults.get(field.name).unwrap_or("")
              }
              if @protocol.validate_config(schema, config) is Some(message) {
                raise @domain.BadRequest(message~)
              }
              ignore(
                tx.execute(
                  "UPDATE pipeline_provider SET config_schema=?,config_json=?,config_revision=config_revision+1,control_status='pending' WHERE id=?",
                  params=[
                    ToJson::to_json(schema).stringify(),
                    ToJson::to_json(config).stringify(),
                    id,
                  ],
                ),
              )
            }
          }
          (None, None) => ()
          _ =>
            raise @domain.BadRequest(
              message="Controller schema and defaults must be sent together.",
            )
        }
        let revision : Int64 = tx
          .query_one(
            "SELECT config_revision FROM pipeline_provider WHERE id=?",
            params=[id],
          )
          .get_name("config_revision")
        ignore(
          tx.execute(
            "UPDATE pipeline_worker SET draining=1,state='failed' WHERE provider_id=? AND last_seen_ms<? AND state NOT IN ('drained','failed') AND NOT EXISTS (SELECT 1 FROM pipeline_job_attempt a WHERE a.worker_id=pipeline_worker.id AND a.status<>'completed')",
            params=[id, now - 180000L],
          ),
        )
        ignore(
          tx.execute(
            "UPDATE pipeline_provider SET controller_id=?,controller_until_ms=?,last_seen_ms=?,observed_revision=?,applied_revision=?,control_status=? WHERE id=?",
            params=[
              request.controller_id,
              now + 60000L,
              now,
              observed,
              applied,
              if observed < revision {
                "pending"
              } else {
                request.status
              },
              id,
            ],
          ),
        )
        control_snapshot(
          tx,
          tx.query_one("SELECT * FROM pipeline_provider WHERE id=?", params=[id]),
        )
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::register_worker(
  self : Coordinator,
  token : String,
  request : @protocol.WorkerRegistration,
) -> @protocol.WorkerView raise {
  check_version(request.version)
  check_token(request.token)
  guard @domain.valid_segment(request.key) && request.key.length() <= 100 else {
    raise @domain.BadRequest(message="Invalid worker key.")
  }
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let parent = authenticate_provider(tx, token)
        let id : Int64 = parent.get_name("id")
        guard !(parent.get_name("mode") : String).is_empty() else {
          raise @domain.BadRequest(message="Not a managed provider.")
        }
        let hash = @identity.hash_token(request.token)
        if tx.query_opt(
            "SELECT token_hash FROM pipeline_worker WHERE provider_id=? AND worker_key=?",
            params=[id, request.key],
          )
          is Some(existing) {
          guard (existing.get_name("token_hash") : String) == hash else {
            raise Conflict("Worker key already registered.")
          }
        } else {
          guard tx.query_opt(
              "SELECT id FROM pipeline_provider WHERE token_hash=? OR registration_hash=? UNION SELECT id FROM pipeline_worker WHERE token_hash=? UNION SELECT id FROM pipeline_job_attempt WHERE token_hash=?",
              params=[hash, hash, hash, hash],
            )
            is None else {
            raise Conflict("Credential already in use.")
          }
          let now = (self.clock)()
          ignore(
            tx.execute(
              "INSERT INTO pipeline_worker(provider_id,worker_key,token_hash,last_seen_ms,idle_since_ms) VALUES(?,?,?,?,?)",
              params=[id, request.key, hash, now, now],
            ),
          )
        }
        worker_view(
          tx.query_one(
            "SELECT w.*, (SELECT count(*) FROM pipeline_job_attempt a WHERE a.worker_id=w.id AND a.status<>'completed') AS active FROM pipeline_worker w WHERE w.provider_id=? AND w.worker_key=?",
            params=[id, request.key],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
fn authenticate_worker(
  tx : @database.DbTransaction,
  token : String,
) -> @database.DbRow raise {
  check_token(token)
  let row = tx.query_opt(
    "SELECT w.*, p.paused,p.revoked,p.config_revision,p.config_json FROM pipeline_worker w JOIN pipeline_provider p ON p.id=w.provider_id WHERE w.token_hash=? AND p.revoked=0",
    params=[@identity.hash_token(token)],
  )
  guard row is Some(row) else {
    raise @domain.Unauthorized(message="Invalid worker credentials.")
  }
  row
}

///|
pub fn Coordinator::sync_worker(
  self : Coordinator,
  token : String,
  request : @protocol.WorkerSyncRequest,
) -> @protocol.WorkerSnapshot raise {
  check_version(request.version)
  guard ["starting", "ready", "busy", "drained", "failed"].contains(
    request.state,
  ) else {
    raise @domain.BadRequest(message="Invalid worker state.")
  }
  let applied = parse_protocol_int64(
    request.applied_revision,
    "Invalid worker revision.",
  )
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = authenticate_worker(tx, token)
        let id : Int64 = row.get_name("id")
        let revision : Int64 = row.get_name("config_revision")
        guard applied <= revision else {
          raise @domain.BadRequest(message="Unknown worker revision.")
        }
        let active = tx.query_opt(
            "SELECT id FROM pipeline_job_attempt WHERE worker_id=? AND status<>'completed'",
            params=[id],
          )
          is Some(_)
        guard !active || ["busy", "failed"].contains(request.state) else {
          raise Conflict("Worker still has an active task.")
        }
        let old_state : String = row.get_name("state")
        let draining : Bool = row.get_name("draining")
        guard !["failed", "drained"].contains(old_state) ||
          request.state == old_state else {
          raise Conflict("Worker is terminal.")
        }
        let now = (self.clock)()
        let state = if draining && request.state == "ready" {
          "drained"
        } else {
          request.state
        }
        let idle = if old_state != "ready" && state == "ready" {
          now
        } else {
          (row.get_name("idle_since_ms") : Int64)
        }
        ignore(
          tx.execute(
            "UPDATE pipeline_worker SET state=?,last_seen_ms=?,applied_revision=?,idle_since_ms=? WHERE id=?",
            params=[state, now, applied, idle, id],
          ),
        )
        {
          version: 1,
          provider_id: (row.get_name("provider_id") : Int64).to_string(),
          worker_id: id.to_string(),
          paused: row.get_name("paused"),
          draining,
          config_revision: revision.to_string(),
          config: @json.from_json(
            @json.parse((row.get_name("config_json") : String)),
          ),
        }
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::drain_worker(
  self : Coordinator,
  token : String,
  worker_id : Int64,
) -> Unit raise {
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let parent = authenticate_provider(tx, token)
        let id : Int64 = parent.get_name("id")
        guard tx.execute(
            "UPDATE pipeline_worker SET draining=1 WHERE id=? AND provider_id=?",
            params=[worker_id, id],
          ) ==
          1 else {
          raise @domain.NotFound(message="Worker not found.")
        }
      },
      immediate=true,
    )
  })
}
