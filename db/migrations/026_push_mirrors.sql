CREATE TABLE repository_mirror (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
 creator_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
 url TEXT NOT NULL,
 active INTEGER NOT NULL CHECK(active IN (0,1)),
 force_push INTEGER NOT NULL CHECK(force_push IN (0,1)),
 prune INTEGER NOT NULL CHECK(prune IN (0,1)),
 version INTEGER NOT NULL DEFAULT 1,
 generation INTEGER NOT NULL DEFAULT 1,
 synced_generation INTEGER NOT NULL DEFAULT 0,
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','syncing','succeeded','failed','disabled')),
 attempts INTEGER NOT NULL DEFAULT 0,
 next_attempt_at TEXT NOT NULL DEFAULT(datetime('now')),
 lease TEXT, locked_at TEXT,
 last_error TEXT NOT NULL DEFAULT '',
 last_success_at TEXT,
 UNIQUE(repository_id,url)
);
CREATE INDEX repository_mirror_pending ON repository_mirror(active,status,next_attempt_at);
CREATE TABLE mirror_attempt (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 mirror_id INTEGER NOT NULL REFERENCES repository_mirror(id) ON DELETE CASCADE,
 generation INTEGER NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('syncing','succeeded','failed')),
 error TEXT NOT NULL DEFAULT '',
 started_at TEXT NOT NULL DEFAULT(datetime('now')),
 completed_at TEXT
);
CREATE TABLE mirror_ref_intent (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
 source_key TEXT NOT NULL, reference TEXT NOT NULL,
 old_sha TEXT NOT NULL, new_sha TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('prepared','ready','aborted')),
 UNIQUE(repository_id,source_key,reference)
);
CREATE INDEX mirror_ref_intent_state ON mirror_ref_intent(state,repository_id);
CREATE TRIGGER mirror_ref_ready AFTER UPDATE OF state ON mirror_ref_intent
WHEN NEW.state='ready' AND OLD.state='prepared' BEGIN
 UPDATE repository_mirror SET generation=generation+1,
 status=CASE WHEN status='syncing' THEN status ELSE 'pending' END,
 attempts=0,next_attempt_at=datetime('now'),last_error=''
 WHERE repository_id=NEW.repository_id AND active=1;
END;
CREATE TRIGGER mirror_merge_push AFTER INSERT ON merge_activity
WHEN NEW.kind='merged' BEGIN
 UPDATE repository_mirror SET generation=generation+1,
 status=CASE WHEN status='syncing' THEN status ELSE 'pending' END,
 attempts=0,next_attempt_at=datetime('now'),last_error=''
 WHERE repository_id=(SELECT repository_id FROM merge_request WHERE id=NEW.merge_request_id) AND active=1;
END;
