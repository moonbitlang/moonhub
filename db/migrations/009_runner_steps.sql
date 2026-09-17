ALTER TABLE pipeline_job_attempt ADD COLUMN execution_id TEXT;
CREATE TABLE pipeline_step (
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  step_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'running', 'success', 'failure', 'timed_out', 'cancelled', 'skipped', 'lost')),
  exit_code INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (attempt_id, step_id),
  UNIQUE (attempt_id, ordinal)
);
