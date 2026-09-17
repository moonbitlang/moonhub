CREATE TABLE pipeline_run (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  number INTEGER NOT NULL CHECK (number > 0),
  requested_by_user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  workflow_path TEXT NOT NULL,
  workflow_name TEXT NOT NULL,
  source_branch TEXT NOT NULL,
  commit_sha TEXT NOT NULL CHECK (length(commit_sha) IN (40, 64)),
  source_ref TEXT NOT NULL UNIQUE,
  definition_version INTEGER NOT NULL CHECK (definition_version > 0),
  workflow_source TEXT NOT NULL,
  definition_json TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'completed')),
  conclusion TEXT CHECK (conclusion IN ('success', 'failure', 'cancelled', 'timed_out', 'lost')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  CHECK ((status = 'completed' AND conclusion IS NOT NULL) OR (status <> 'completed' AND conclusion IS NULL)),
  UNIQUE (repository_id, number)
);
CREATE INDEX pipeline_run_repository ON pipeline_run(repository_id, number);

CREATE TRIGGER pipeline_run_snapshot_immutable
BEFORE UPDATE OF repository_id, number, requested_by_user_id, workflow_path,
  workflow_name, source_branch, commit_sha, source_ref, definition_version,
  workflow_source, definition_json ON pipeline_run
BEGIN
  SELECT RAISE(ABORT, 'pipeline run snapshots are immutable');
END;

CREATE TABLE pipeline_job (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id INTEGER NOT NULL REFERENCES pipeline_run(id) ON DELETE CASCADE,
  job_key TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  status TEXT NOT NULL CHECK (status IN ('waiting', 'queued', 'leased', 'running', 'completed')),
  conclusion TEXT CHECK (conclusion IN ('success', 'failure', 'cancelled', 'timed_out', 'lost', 'skipped')),
  CHECK ((status = 'completed' AND conclusion IS NOT NULL) OR (status <> 'completed' AND conclusion IS NULL)),
  UNIQUE (run_id, job_key),
  UNIQUE (run_id, ordinal)
);
CREATE INDEX pipeline_job_status ON pipeline_job(status, id);

CREATE TABLE pipeline_job_need (
  run_id INTEGER NOT NULL,
  job_key TEXT NOT NULL,
  needs_job_key TEXT NOT NULL,
  PRIMARY KEY (run_id, job_key, needs_job_key),
  CHECK (job_key <> needs_job_key),
  FOREIGN KEY (run_id, job_key) REFERENCES pipeline_job(run_id, job_key) ON DELETE CASCADE,
  FOREIGN KEY (run_id, needs_job_key) REFERENCES pipeline_job(run_id, job_key) ON DELETE CASCADE
);

CREATE TABLE pipeline_job_attempt (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id INTEGER NOT NULL REFERENCES pipeline_job(id) ON DELETE CASCADE,
  number INTEGER NOT NULL CHECK (number > 0),
  status TEXT NOT NULL CHECK (status IN ('leased', 'running', 'completed')),
  conclusion TEXT CHECK (conclusion IN ('success', 'failure', 'cancelled', 'timed_out', 'lost')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  finished_at TEXT,
  CHECK ((status = 'completed' AND conclusion IS NOT NULL AND finished_at IS NOT NULL)
    OR (status <> 'completed' AND conclusion IS NULL AND finished_at IS NULL)),
  UNIQUE (job_id, number)
);
CREATE UNIQUE INDEX pipeline_job_active_attempt ON pipeline_job_attempt(job_id)
  WHERE status <> 'completed';
