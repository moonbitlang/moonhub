CREATE TABLE mail_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  transport TEXT NOT NULL DEFAULT 'file'
    CHECK (transport IN ('file', 'smtp')),
  smtp_host TEXT NOT NULL DEFAULT '',
  smtp_port INTEGER NOT NULL DEFAULT 587
    CHECK (smtp_port BETWEEN 1 AND 65535),
  smtp_security TEXT NOT NULL DEFAULT 'starttls'
    CHECK (smtp_security IN ('plain', 'starttls', 'tls')),
  smtp_auth TEXT NOT NULL DEFAULT 'plain'
    CHECK (smtp_auth IN ('none', 'plain', 'login', 'xoauth2')),
  smtp_username TEXT NOT NULL DEFAULT '',
  smtp_password TEXT NOT NULL DEFAULT '',
  smtp_tls_trust TEXT NOT NULL DEFAULT 'system'
    CHECK (smtp_tls_trust IN ('system', 'insecure', 'custom')),
  smtp_tls_root_cert_file TEXT NOT NULL DEFAULT '',
  smtp_helo_name TEXT NOT NULL DEFAULT 'localhost',
  smtp_from TEXT NOT NULL DEFAULT 'moonhub@localhost',
  updated_by_user_id INTEGER REFERENCES "user"(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
