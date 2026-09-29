ALTER TABLE merge_request ADD COLUMN check_generation INTEGER NOT NULL DEFAULT 1;
ALTER TABLE merge_request ADD COLUMN checks_poll_after INTEGER NOT NULL DEFAULT 0;

CREATE TABLE branch_required_check (
  repository_id INTEGER NOT NULL,
  branch TEXT NOT NULL,
  workflow_path TEXT NOT NULL,
  PRIMARY KEY (repository_id, branch, workflow_path),
  FOREIGN KEY (repository_id, branch) REFERENCES branch_rule(repository_id, branch) ON DELETE CASCADE
);

CREATE TABLE merge_check (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  merge_request_id INTEGER NOT NULL,
  version INTEGER NOT NULL,
  generation INTEGER NOT NULL,
  workflow_path TEXT NOT NULL,
  requested_by_user_id INTEGER REFERENCES "user"(id),
  state TEXT NOT NULL DEFAULT 'awaiting_approval' CHECK (state IN ('awaiting_approval', 'pending', 'queued', 'running', 'completed', 'error')),
  conclusion TEXT NOT NULL DEFAULT '',
  run_number INTEGER,
  last_error TEXT NOT NULL DEFAULT '',
  retry_after INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (merge_request_id, version) REFERENCES merge_revision(merge_request_id, version) ON DELETE CASCADE,
  UNIQUE (merge_request_id, version, generation, workflow_path)
);
CREATE INDEX merge_check_pending ON merge_check(state, retry_after, id);
CREATE TRIGGER merge_check_context_immutable BEFORE UPDATE OF merge_request_id, version, generation, workflow_path ON merge_check
BEGIN
  SELECT RAISE(ABORT, 'merge check context is immutable');
END;
ALTER TABLE pipeline_run ADD COLUMN merge_check_id INTEGER REFERENCES merge_check(id);
CREATE INDEX pipeline_run_merge_check ON pipeline_run(merge_check_id);
CREATE TRIGGER pipeline_run_merge_check_immutable BEFORE UPDATE OF merge_check_id ON pipeline_run
BEGIN
  SELECT RAISE(ABORT, 'pipeline merge check identity is immutable');
END;
CREATE TRIGGER pipeline_run_merge_check_result AFTER UPDATE OF status, conclusion ON pipeline_run
WHEN NEW.merge_check_id IS NOT NULL
BEGIN
  UPDATE merge_check SET state = NEW.status, conclusion = COALESCE(NEW.conclusion, '')
  WHERE id = NEW.merge_check_id AND run_number = NEW.number;
END;
