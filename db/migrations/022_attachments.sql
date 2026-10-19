-- Image bytes live in persistent storage, outside Git repositories.
CREATE TABLE attachment (
  id TEXT PRIMARY KEY CHECK (length(id) = 64),
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  uploader_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  filename TEXT NOT NULL,
  media_type TEXT NOT NULL CHECK (media_type IN ('image/png', 'image/jpeg', 'image/gif', 'image/webp')),
  byte_size INTEGER NOT NULL CHECK (byte_size > 0 AND byte_size <= 5242880),
  sha256 TEXT NOT NULL,
  ready INTEGER NOT NULL DEFAULT 0 CHECK (ready IN (0, 1, 2)),
  claimed INTEGER NOT NULL DEFAULT 0 CHECK (claimed IN (0, 1)),
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX attachment_pending ON attachment(repository_id, uploader_id, created_at);
CREATE TABLE attachment_reference (
  attachment_id TEXT NOT NULL REFERENCES attachment(id) ON DELETE CASCADE,
  merge_request_id INTEGER REFERENCES merge_request(id) ON DELETE CASCADE,
  issue_id INTEGER REFERENCES issue(id) ON DELETE CASCADE,
  merge_activity_id INTEGER REFERENCES merge_activity(id) ON DELETE CASCADE,
  issue_activity_id INTEGER REFERENCES issue_activity(id) ON DELETE CASCADE,
  CHECK ((merge_request_id IS NOT NULL) + (issue_id IS NOT NULL) +
    (merge_activity_id IS NOT NULL) + (issue_activity_id IS NOT NULL) = 1)
);
CREATE UNIQUE INDEX attachment_mr_reference ON attachment_reference(attachment_id, merge_request_id);
CREATE UNIQUE INDEX attachment_issue_reference ON attachment_reference(attachment_id, issue_id);
CREATE UNIQUE INDEX attachment_mr_comment_reference ON attachment_reference(attachment_id, merge_activity_id);
CREATE UNIQUE INDEX attachment_issue_comment_reference ON attachment_reference(attachment_id, issue_activity_id);
