ALTER TABLE repository ADD COLUMN pipeline_push_enabled INTEGER NOT NULL DEFAULT 0
  CHECK (pipeline_push_enabled IN (0, 1));

CREATE TABLE repository_ref_event (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  actor_id INTEGER NOT NULL REFERENCES "user"(id),
  source_key TEXT NOT NULL,
  reference TEXT NOT NULL,
  old_sha TEXT NOT NULL,
  new_sha TEXT NOT NULL,
  pin_ref TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL CHECK (state IN ('prepared', 'committed', 'ready', 'processed', 'aborted')),
  last_error TEXT NOT NULL DEFAULT '',
  retry_after INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (repository_id, source_key, reference)
);
CREATE INDEX repository_ref_event_pending ON repository_ref_event(state, id);
ALTER TABLE pipeline_run ADD COLUMN trigger_event_id INTEGER REFERENCES repository_ref_event(id);
CREATE UNIQUE INDEX pipeline_run_push_unique ON pipeline_run(trigger_event_id, workflow_path)
  WHERE trigger_event_id IS NOT NULL;
CREATE TRIGGER pipeline_run_trigger_immutable BEFORE UPDATE OF trigger_event_id ON pipeline_run
BEGIN
  SELECT RAISE(ABORT, 'pipeline trigger identity is immutable');
END;
