CREATE TABLE repository_deploy_key (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER REFERENCES repository(id) ON DELETE SET NULL,
  title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  public_key TEXT NOT NULL UNIQUE CHECK (public_key <> ''),
  fingerprint TEXT NOT NULL UNIQUE CHECK (fingerprint <> ''),
  write_access INTEGER NOT NULL DEFAULT 0 CHECK (write_access IN (0, 1)),
  creator_id INTEGER NOT NULL REFERENCES "user"(id),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_used_at TEXT,
  revoked_at TEXT
);
CREATE INDEX repository_deploy_key_repository ON repository_deploy_key(repository_id);

-- Retain key tombstones after deletion: an old credential must never acquire
-- a new repository or user identity, including when a path is recreated.
CREATE TRIGGER repository_deploy_key_delete BEFORE DELETE ON repository
BEGIN
  UPDATE repository_deploy_key SET revoked_at = COALESCE(revoked_at, datetime('now'))
    WHERE repository_id = OLD.id;
END;

CREATE TRIGGER repository_deploy_key_identity_immutable
BEFORE UPDATE OF public_key, fingerprint, creator_id ON repository_deploy_key
BEGIN
  SELECT RAISE(ABORT, 'deploy key identity is immutable');
END;
CREATE TRIGGER repository_deploy_key_binding_immutable
BEFORE UPDATE OF repository_id ON repository_deploy_key
WHEN NEW.repository_id IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'deploy key binding is immutable');
END;

CREATE TRIGGER repository_deploy_key_no_user_collision BEFORE INSERT ON repository_deploy_key
WHEN EXISTS (SELECT 1 FROM ssh_key WHERE fingerprint = NEW.fingerprint OR public_key = NEW.public_key)
BEGIN
  SELECT RAISE(ABORT, 'SSH public key is already registered');
END;
CREATE TRIGGER ssh_key_no_deploy_collision BEFORE INSERT ON ssh_key
WHEN EXISTS (SELECT 1 FROM repository_deploy_key WHERE fingerprint = NEW.fingerprint OR public_key = NEW.public_key)
BEGIN
  SELECT RAISE(ABORT, 'SSH public key is already registered');
END;
CREATE TRIGGER ssh_key_update_no_deploy_collision BEFORE UPDATE OF fingerprint, public_key ON ssh_key
WHEN EXISTS (SELECT 1 FROM repository_deploy_key WHERE fingerprint = NEW.fingerprint OR public_key = NEW.public_key)
BEGIN
  SELECT RAISE(ABORT, 'SSH public key is already registered');
END;
