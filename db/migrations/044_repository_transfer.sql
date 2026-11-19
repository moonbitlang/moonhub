-- While a transfer is uncommitted, its repository row reserves the source
-- name. The journal reserves the destination and survives process restarts.
CREATE TABLE repository_transfer (
  repository_id INTEGER PRIMARY KEY REFERENCES repository(id) ON DELETE RESTRICT,
  target_team_id INTEGER NOT NULL REFERENCES team(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  UNIQUE (target_team_id, name)
);

CREATE TRIGGER repository_transfer_name_guard BEFORE INSERT ON repository
WHEN EXISTS (
  SELECT 1 FROM repository_transfer
  WHERE target_team_id=NEW.team_id AND name=NEW.name
)
BEGIN
  SELECT RAISE(ABORT, 'repository name is reserved by an unfinished transfer');
END;
