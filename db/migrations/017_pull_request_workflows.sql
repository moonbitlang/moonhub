ALTER TABLE merge_request ADD COLUMN workflow_event TEXT NOT NULL DEFAULT 'opened'
  CHECK (workflow_event IN ('opened', 'reopened', 'synchronize'));
ALTER TABLE merge_request ADD COLUMN workflow_event_pending INTEGER NOT NULL DEFAULT 0
  CHECK (workflow_event_pending IN (0, 1));
ALTER TABLE merge_check ADD COLUMN automatic INTEGER NOT NULL DEFAULT 0
  CHECK (automatic IN (0, 1));

-- Execution approval can precede asynchronous workflow discovery. Bind it to
-- the exact proposed source and generation; API collaboration writes add none.
CREATE TABLE merge_execution_approval (
  merge_request_id INTEGER NOT NULL REFERENCES merge_request(id) ON DELETE CASCADE,
  generation INTEGER NOT NULL,
  source_sha TEXT NOT NULL,
  user_id INTEGER NOT NULL REFERENCES "user"(id),
  PRIMARY KEY (merge_request_id, generation, source_sha, user_id)
);
INSERT OR IGNORE INTO merge_execution_approval
SELECT c.merge_request_id, c.generation, v.source_sha, c.requested_by_user_id
FROM merge_check c JOIN merge_revision v
  ON v.merge_request_id = c.merge_request_id AND v.version = c.version
WHERE c.requested_by_user_id IS NOT NULL;
