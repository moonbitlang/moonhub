CREATE TABLE pipeline_provider (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  token_hash TEXT NOT NULL UNIQUE,
  paused INTEGER NOT NULL DEFAULT 0 CHECK (paused IN (0, 1)),
  revoked INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0, 1))
);
CREATE TABLE pipeline_provider_repository (
  provider_id INTEGER NOT NULL REFERENCES pipeline_provider(id) ON DELETE CASCADE,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  PRIMARY KEY (provider_id, repository_id)
);
CREATE TABLE pipeline_provider_label (
  provider_id INTEGER NOT NULL REFERENCES pipeline_provider(id) ON DELETE CASCADE,
  label TEXT NOT NULL,
  PRIMARY KEY (provider_id, label)
);
CREATE TABLE pipeline_job_label (
  job_id INTEGER NOT NULL REFERENCES pipeline_job(id) ON DELETE CASCADE,
  label TEXT NOT NULL,
  PRIMARY KEY (job_id, label)
);
INSERT INTO pipeline_job_label(job_id, label)
SELECT j.id, label.value
FROM pipeline_job AS j JOIN pipeline_run AS r ON r.id = j.run_id,
  json_each(r.definition_json, '$.jobs') AS job,
  json_each(job.value, '$.runs_on') AS label
WHERE json_extract(job.value, '$.id') = j.job_key;

ALTER TABLE pipeline_run ADD COLUMN cancel_requested INTEGER NOT NULL DEFAULT 0 CHECK (cancel_requested IN (0, 1));
ALTER TABLE pipeline_job_attempt ADD COLUMN provider_id INTEGER REFERENCES pipeline_provider(id);
ALTER TABLE pipeline_job_attempt ADD COLUMN request_id TEXT;
ALTER TABLE pipeline_job_attempt ADD COLUMN token_hash TEXT;
ALTER TABLE pipeline_job_attempt ADD COLUMN lease_until_ms INTEGER;
ALTER TABLE pipeline_job_attempt ADD COLUMN started_at_ms INTEGER;
ALTER TABLE pipeline_job_attempt ADD COLUMN deadline_ms INTEGER;
ALTER TABLE pipeline_job_attempt ADD COLUMN cancel_at_ms INTEGER;
ALTER TABLE pipeline_job_attempt ADD COLUMN log_sequence INTEGER NOT NULL DEFAULT 0;
ALTER TABLE pipeline_job_attempt ADD COLUMN log_bytes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE pipeline_job_attempt ADD COLUMN result_hash TEXT;
ALTER TABLE pipeline_job_attempt ADD COLUMN reported_conclusion TEXT;
CREATE UNIQUE INDEX pipeline_attempt_request ON pipeline_job_attempt(provider_id, request_id);
CREATE UNIQUE INDEX pipeline_attempt_token ON pipeline_job_attempt(token_hash);
CREATE INDEX pipeline_attempt_lease ON pipeline_job_attempt(lease_until_ms)
  WHERE status <> 'completed';

CREATE TABLE pipeline_log_chunk (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  sequence INTEGER,
  step_id TEXT NOT NULL,
  stream TEXT NOT NULL CHECK (stream IN ('stdout', 'stderr')),
  content TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  UNIQUE (attempt_id, sequence)
);
CREATE INDEX pipeline_log_cursor ON pipeline_log_chunk(attempt_id, id);
CREATE TABLE pipeline_log_tail (
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  step_id TEXT NOT NULL,
  stream TEXT NOT NULL,
  content TEXT NOT NULL,
  PRIMARY KEY (attempt_id, step_id, stream)
);
