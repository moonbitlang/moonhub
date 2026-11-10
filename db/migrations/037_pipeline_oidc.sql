CREATE TABLE IF NOT EXISTS pipeline_oidc_runtime (
  token_hash TEXT PRIMARY KEY,
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  execution_id TEXT NOT NULL,
  expires_ms INTEGER NOT NULL,
  requests INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS pipeline_oidc_runtime_attempt ON pipeline_oidc_runtime(attempt_id);
