ALTER TABLE repository ADD COLUMN ready INTEGER NOT NULL DEFAULT 1
  CHECK (ready IN (0, 1));

CREATE TABLE repository_job (
  repository_id INTEGER PRIMARY KEY REFERENCES repository(id) ON DELETE CASCADE,
  requested_by_user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  source_url TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'running', 'succeeded', 'failed')),
  stage_token TEXT NOT NULL DEFAULT '',
  attempt_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX repository_job_status_index ON repository_job (status, repository_id);
