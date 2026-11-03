CREATE TABLE IF NOT EXISTS repository_secret (
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  branch TEXT NOT NULL,
  workflow_path TEXT NOT NULL,
  version INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (repository_id, name)
);

-- Execution credentials never enter the immutable run or assignment snapshots.
-- Retain issued values only until completion so rotation cannot defeat masking.
CREATE TABLE IF NOT EXISTS pipeline_secret_delivery (
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  step_id TEXT NOT NULL,
  env_name TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (attempt_id, step_id, env_name)
);
