CREATE TABLE IF NOT EXISTS repository_release (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  tag TEXT NOT NULL,
  commit_sha TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  draft INTEGER NOT NULL DEFAULT 1 CHECK(draft IN(0,1)),
  prerelease INTEGER NOT NULL DEFAULT 0 CHECK(prerelease IN(0,1)),
  deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN(0,1)),
  revision INTEGER NOT NULL DEFAULT 1,
  author_id INTEGER NOT NULL REFERENCES user(id),
  created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  published_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS repository_release_tag ON repository_release(repository_id,tag) WHERE deleted=0;
CREATE TABLE IF NOT EXISTS repository_release_latest (
  repository_id INTEGER PRIMARY KEY REFERENCES repository(id) ON DELETE CASCADE,
  release_id INTEGER NOT NULL REFERENCES repository_release(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS release_asset (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  release_id INTEGER NOT NULL REFERENCES repository_release(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  label TEXT NOT NULL DEFAULT '',
  media_type TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN('pending','ready','deleted')),
  commit_sha TEXT NOT NULL,
  storage_key TEXT NOT NULL UNIQUE,
  location TEXT NOT NULL,
  size INTEGER NOT NULL DEFAULT 0,
  digest TEXT NOT NULL DEFAULT '',
  expires_ms INTEGER NOT NULL,
  created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS release_asset_name ON release_asset(release_id,name) WHERE state<>'deleted';
CREATE TABLE IF NOT EXISTS release_blob_garbage (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  location TEXT NOT NULL,
  storage_key TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'namespace' CHECK(kind IN('namespace','object')),
  due_ms INTEGER NOT NULL,
  UNIQUE(location,storage_key,kind)
);
CREATE TRIGGER IF NOT EXISTS release_asset_delete BEFORE DELETE ON release_asset BEGIN
  INSERT OR IGNORE INTO release_blob_garbage(location,storage_key,due_ms)
  VALUES(old.location,old.storage_key,CAST(unixepoch('now') AS INTEGER)*1000+600000);
END;
CREATE TABLE IF NOT EXISTS pipeline_api_runtime (
  token_hash TEXT PRIMARY KEY,
  attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  execution_id TEXT NOT NULL,
  expires_ms INTEGER NOT NULL
);
ALTER TABLE pipeline_run ADD COLUMN display_title TEXT NOT NULL DEFAULT '';
CREATE TRIGGER IF NOT EXISTS pipeline_display_title_immutable BEFORE UPDATE OF display_title ON pipeline_run BEGIN
  SELECT RAISE(ABORT,'pipeline display title is immutable');
END;
CREATE TABLE IF NOT EXISTS pipeline_schedule_config (
  repository_id INTEGER PRIMARY KEY REFERENCES repository(id) ON DELETE CASCADE,
  actor_id INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
  enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN(0,1)),
  polled_minute INTEGER NOT NULL DEFAULT -1,
  last_error TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS pipeline_schedule_tick (
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  workflow_path TEXT NOT NULL,
  minute INTEGER NOT NULL,
  run_id INTEGER NOT NULL REFERENCES pipeline_run(id) ON DELETE CASCADE,
  PRIMARY KEY(repository_id,workflow_path,minute)
);
