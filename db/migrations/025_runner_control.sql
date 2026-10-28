ALTER TABLE pipeline_provider ADD COLUMN mode TEXT NOT NULL DEFAULT '';
ALTER TABLE pipeline_provider ADD COLUMN registration_hash TEXT;
ALTER TABLE pipeline_provider ADD COLUMN config_schema TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(config_schema));
ALTER TABLE pipeline_provider ADD COLUMN config_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(config_json));
ALTER TABLE pipeline_provider ADD COLUMN config_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE pipeline_provider ADD COLUMN observed_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE pipeline_provider ADD COLUMN applied_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE pipeline_provider ADD COLUMN control_status TEXT NOT NULL DEFAULT 'unregistered';
ALTER TABLE pipeline_provider ADD COLUMN controller_id TEXT;
ALTER TABLE pipeline_provider ADD COLUMN controller_until_ms INTEGER NOT NULL DEFAULT 0;
CREATE TABLE pipeline_worker (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  provider_id INTEGER NOT NULL REFERENCES pipeline_provider(id),
  worker_key TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL DEFAULT 'starting' CHECK(state IN ('starting','ready','busy','drained','failed')),
  draining INTEGER NOT NULL DEFAULT 0 CHECK(draining IN (0,1)),
  applied_revision INTEGER NOT NULL DEFAULT 0,
  last_seen_ms INTEGER NOT NULL,
  idle_since_ms INTEGER NOT NULL,
  UNIQUE(provider_id,worker_key)
);
ALTER TABLE pipeline_job_attempt ADD COLUMN worker_id INTEGER REFERENCES pipeline_worker(id);
CREATE INDEX pipeline_worker_provider ON pipeline_worker(provider_id);
CREATE UNIQUE INDEX pipeline_worker_active_attempt ON pipeline_job_attempt(worker_id) WHERE worker_id IS NOT NULL AND status <> 'completed';
