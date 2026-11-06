-- Nonsecret configuration values may be read by anyone with repository access.
-- AUTOINCREMENT makes optimistic versions safe across deletion and recreation.
CREATE TABLE IF NOT EXISTS repository_variable (
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  version INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (repository_id, name)
);
