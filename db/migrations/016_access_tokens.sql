CREATE TABLE access_token (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  token_hash TEXT NOT NULL UNIQUE,
  permission TEXT NOT NULL CHECK (permission IN ('read', 'write', 'execute', 'merge')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  last_used_at TEXT
);
CREATE INDEX access_token_owner ON access_token(user_id, id);
