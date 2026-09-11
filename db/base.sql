BEGIN;

CREATE TABLE "user" (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name_key TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  email TEXT UNIQUE,
  password_hash TEXT NOT NULL,
  is_site_admin INTEGER NOT NULL DEFAULT 0 CHECK (is_site_admin IN (0, 1)),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  CHECK (name_key <> 'assets'),
  CHECK (display_name <> ''),
  CHECK (email IS NULL OR (email = lower(email) AND email <> '')),
  CHECK (password_hash <> '')
);

CREATE TABLE team (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name_key TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('personal', 'org')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  CHECK (name_key <> 'assets'),
  CHECK (display_name <> '')
);

CREATE TABLE team_member (
  team_id INTEGER NOT NULL REFERENCES team(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (team_id, user_id)
);

CREATE INDEX team_member_user_id_index ON team_member (user_id);

CREATE TABLE invitation (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('root', 'team_member')),
  email TEXT NOT NULL,
  name_key TEXT NOT NULL,
  display_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  is_site_admin INTEGER NOT NULL DEFAULT 0 CHECK (is_site_admin IN (0, 1)),
  team_id INTEGER REFERENCES team(id) ON DELETE CASCADE,
  team_role TEXT CHECK (team_role IS NULL OR team_role IN ('admin', 'member')),
  invited_by_user_id INTEGER REFERENCES "user"(id) ON DELETE RESTRICT,
  accepted_user_id INTEGER REFERENCES "user"(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'sent'
    CHECK (status IN ('sent', 'accepted', 'revoked', 'expired')),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL DEFAULT (datetime('now', '+7 days')),
  accepted_at TEXT,
  revoked_at TEXT,
  CHECK (email = lower(email) AND email <> ''),
  CHECK (name_key <> 'assets'),
  CHECK (display_name <> ''),
  CHECK (password_hash <> ''),
  CHECK (
    (kind = 'root' AND is_site_admin = 1 AND team_id IS NULL AND
      team_role IS NULL AND invited_by_user_id IS NULL)
    OR
    (kind = 'team_member' AND is_site_admin = 0 AND team_id IS NOT NULL AND
      team_role IN ('admin', 'member') AND invited_by_user_id IS NOT NULL)
  )
);

CREATE INDEX invitation_team_id_index ON invitation (team_id);
CREATE INDEX invitation_email_index ON invitation (email);
CREATE INDEX invitation_accepted_user_id_index ON invitation (accepted_user_id);
CREATE UNIQUE INDEX invitation_sent_name_key_index
  ON invitation (name_key) WHERE status = 'sent';
CREATE UNIQUE INDEX invitation_sent_email_index
  ON invitation (email) WHERE status = 'sent';

CREATE TABLE session (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  last_seen_at TEXT,
  CHECK (token_hash <> ''),
  CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);

CREATE INDEX session_user_id_index ON session (user_id);
CREATE INDEX session_expires_at_index ON session (expires_at);

CREATE TABLE invitation_session (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  invitation_id INTEGER NOT NULL REFERENCES invitation(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  CHECK (token_hash <> ''),
  CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);

CREATE INDEX invitation_session_invitation_id_index
  ON invitation_session (invitation_id);

CREATE TABLE email_outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  invitation_id INTEGER REFERENCES invitation(id) ON DELETE SET NULL,
  to_email TEXT NOT NULL,
  subject TEXT NOT NULL,
  body TEXT NOT NULL,
  template TEXT NOT NULL DEFAULT 'plain',
  payload TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'sent', 'failed')),
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at TEXT NOT NULL DEFAULT (datetime('now')),
  locked_at TEXT,
  locked_by TEXT,
  last_error TEXT,
  provider_message_id TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  sent_at TEXT,
  CHECK (to_email = lower(to_email) AND to_email <> ''),
  CHECK (subject <> ''),
  CHECK (body <> ''),
  CHECK (template <> ''),
  CHECK (locked_by IS NULL OR locked_by <> ''),
  CHECK (last_error IS NULL OR last_error <> ''),
  CHECK (provider_message_id IS NULL OR provider_message_id <> '')
);

CREATE INDEX email_outbox_to_email_index ON email_outbox (to_email);
CREATE INDEX email_outbox_invitation_id_index ON email_outbox (invitation_id);
CREATE INDEX email_outbox_sent_at_index ON email_outbox (sent_at);
CREATE INDEX email_outbox_pending_index
  ON email_outbox (next_attempt_at, id) WHERE status = 'pending';

CREATE TABLE repository (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  team_id INTEGER NOT NULL REFERENCES team(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  display_name TEXT,
  visibility TEXT NOT NULL DEFAULT 'private'
    CHECK (visibility IN ('public', 'private')),
  git_path TEXT,
  default_branch TEXT NOT NULL DEFAULT 'HEAD',
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (team_id, name),
  CHECK (name NOT IN ('.', '..')),
  CHECK (display_name IS NULL OR display_name <> ''),
  CHECK (git_path IS NULL OR git_path <> ''),
  CHECK (default_branch <> '')
);

CREATE INDEX repository_team_id_index ON repository (team_id);
CREATE INDEX repository_visibility_index ON repository (visibility);

COMMIT;
