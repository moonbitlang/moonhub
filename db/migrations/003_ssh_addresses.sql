CREATE TABLE site_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  ssh_public_host TEXT NOT NULL CHECK (ssh_public_host <> ''),
  ssh_public_port INTEGER NOT NULL CHECK (ssh_public_port BETWEEN 1 AND 65535),
  updated_by_user_id INTEGER REFERENCES "user"(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

ALTER TABLE repository_job ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'legacy'
  CHECK (source_kind IN ('legacy', 'external', 'local'));
ALTER TABLE repository_job ADD COLUMN source_repository_id INTEGER
  REFERENCES repository(id) ON DELETE SET NULL;
