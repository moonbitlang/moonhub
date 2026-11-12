-- No repository/team foreign key: this manifest must outlive its source.
CREATE TABLE IF NOT EXISTS repository_deletion (
  repository_id INTEGER PRIMARY KEY,
  owner TEXT NOT NULL,
  name TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  next_attempt_at TEXT NOT NULL DEFAULT (datetime('now')),
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT NOT NULL DEFAULT '',
  UNIQUE(owner, name)
);
CREATE TABLE IF NOT EXISTS repository_deletion_resource (
  repository_id INTEGER NOT NULL REFERENCES repository_deletion(repository_id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK(kind IN ('attachment', 'artifact', 'mirror')),
  resource TEXT NOT NULL,
  PRIMARY KEY(repository_id, kind, resource)
);
-- Enforce reservations for every registration path, including concurrent inserts.
CREATE TRIGGER IF NOT EXISTS repository_deletion_reservation BEFORE INSERT ON repository
WHEN EXISTS (
  SELECT 1 FROM repository_deletion d JOIN team t ON t.name_key=d.owner
  WHERE t.id=NEW.team_id AND d.name=NEW.name
)
BEGIN
  SELECT RAISE(ABORT, 'repository cleanup is pending; retry after cleanup completes');
END;
