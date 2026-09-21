CREATE TABLE password_reset (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE CHECK (length(token_hash) = 64),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL DEFAULT (datetime('now', '+30 minutes')),
  used_at TEXT
);

CREATE INDEX password_reset_user_created_index ON password_reset (user_id, created_at);

ALTER TABLE email_outbox ADD COLUMN password_reset_id INTEGER
  REFERENCES password_reset(id) ON DELETE SET NULL;
CREATE INDEX email_outbox_password_reset_index ON email_outbox (password_reset_id);
