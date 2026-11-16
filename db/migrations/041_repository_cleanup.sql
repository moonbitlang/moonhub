-- Journals have no foreign keys: cleanup must survive repository deletion.
-- Paths are relative to the repository root and validated again by the worker.
CREATE TABLE repository_file_garbage (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL,
  owner TEXT NOT NULL,
  name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('git','mirror')),
  resource_id INTEGER NOT NULL,
  path TEXT NOT NULL UNIQUE,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT NOT NULL DEFAULT '',
  next_attempt_at TEXT NOT NULL DEFAULT(datetime('now'))
);
CREATE TRIGGER repository_cleanup_name_guard BEFORE INSERT ON repository
WHEN EXISTS (
  SELECT 1 FROM repository_file_garbage g JOIN team t ON t.name_key=g.owner
  WHERE t.id=NEW.team_id AND g.name=NEW.name AND g.kind='git'
)
BEGIN
  SELECT RAISE(ABORT,'repository files are still being deleted; retry later');
END;

CREATE TABLE attachment_file_garbage (
  id TEXT PRIMARY KEY,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT NOT NULL DEFAULT '',
  next_attempt_at TEXT NOT NULL DEFAULT(datetime('now'))
);
CREATE TRIGGER attachment_storage_delete BEFORE DELETE ON attachment
BEGIN
  INSERT OR IGNORE INTO attachment_file_garbage(id) VALUES(OLD.id);
END;
