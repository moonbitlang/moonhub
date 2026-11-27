CREATE TABLE access_token_next (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  token_hash TEXT NOT NULL UNIQUE,
  permission TEXT NOT NULL CHECK (permission IN ('read', 'write', 'execute', 'merge', 'ssh')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  last_used_at TEXT
);

INSERT INTO access_token_next
  (id, user_id, name, token_hash, permission, created_at, expires_at, revoked_at, last_used_at)
SELECT id, user_id, name, token_hash, permission, created_at, expires_at, revoked_at, last_used_at
FROM access_token;

-- Preserve the sequence even when the highest IDs have been deleted.
DELETE FROM sqlite_sequence WHERE name = 'access_token_next';
INSERT INTO sqlite_sequence(name, seq)
SELECT 'access_token_next', seq FROM sqlite_sequence WHERE name = 'access_token';

DROP TABLE access_token;
ALTER TABLE access_token_next RENAME TO access_token;
CREATE INDEX access_token_owner ON access_token(user_id, id);
