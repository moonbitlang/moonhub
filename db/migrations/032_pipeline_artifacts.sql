CREATE TABLE pipeline_artifact_runtime (
  token_hash TEXT PRIMARY KEY,
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  execution_id TEXT NOT NULL,
  origin TEXT NOT NULL,
  expires_ms INTEGER NOT NULL
);
CREATE INDEX pipeline_artifact_runtime_attempt ON pipeline_artifact_runtime(attempt_id);
CREATE TABLE pipeline_artifact (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  run_id INTEGER NOT NULL REFERENCES pipeline_run(id) ON DELETE CASCADE,
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  storage_key TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL CHECK(state IN ('pending','assembling','uploaded','ready','deleted')),
  size INTEGER NOT NULL DEFAULT 0,
  digest TEXT NOT NULL DEFAULT '',
  created_ms INTEGER NOT NULL,
  expires_ms INTEGER NOT NULL,
  generation TEXT NOT NULL DEFAULT '',
  block_order TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX pipeline_artifact_name ON pipeline_artifact(run_id,name) WHERE state <> 'deleted';
CREATE INDEX pipeline_artifact_cleanup ON pipeline_artifact(state,expires_ms,id);
CREATE TABLE pipeline_artifact_block (
  artifact_id INTEGER NOT NULL REFERENCES pipeline_artifact(id) ON DELETE CASCADE,
  block_id TEXT NOT NULL,
  file_key TEXT NOT NULL,
  size INTEGER NOT NULL,
  digest TEXT NOT NULL,
  PRIMARY KEY(artifact_id,block_id)
);
CREATE TABLE pipeline_artifact_capability (
  token_hash TEXT PRIMARY KEY,
  runtime_hash TEXT NOT NULL REFERENCES pipeline_artifact_runtime(token_hash) ON DELETE CASCADE,
  artifact_id INTEGER NOT NULL REFERENCES pipeline_artifact(id) ON DELETE CASCADE,
  operation TEXT NOT NULL CHECK(operation IN ('write','read')),
  expires_ms INTEGER NOT NULL
);
CREATE INDEX pipeline_artifact_runtime_expiry ON pipeline_artifact_runtime(expires_ms);
CREATE INDEX pipeline_artifact_run ON pipeline_artifact(run_id,id);
CREATE INDEX pipeline_artifact_capability_runtime ON pipeline_artifact_capability(runtime_hash);
CREATE INDEX pipeline_artifact_capability_artifact ON pipeline_artifact_capability(artifact_id);
CREATE INDEX pipeline_artifact_capability_expiry ON pipeline_artifact_capability(expires_ms);
