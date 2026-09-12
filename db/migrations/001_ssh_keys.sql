CREATE TABLE ssh_key (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  title TEXT NOT NULL CHECK (title <> ''),
  public_key TEXT NOT NULL UNIQUE CHECK (public_key <> ''),
  fingerprint TEXT NOT NULL UNIQUE CHECK (fingerprint <> ''),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_used_at TEXT,
  revoked_at TEXT
);

CREATE INDEX ssh_key_user_id_index ON ssh_key (user_id);
