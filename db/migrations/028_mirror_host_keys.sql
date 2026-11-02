ALTER TABLE repository_mirror ADD COLUMN host_keys TEXT NOT NULL DEFAULT '';

CREATE TABLE mirror_host_check (
  mirror_id INTEGER PRIMARY KEY REFERENCES repository_mirror(id) ON DELETE CASCADE,
  version INTEGER NOT NULL,
  url TEXT NOT NULL,
  challenge TEXT NOT NULL,
  host_keys TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
