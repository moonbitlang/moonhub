-- Root activity IDs remain stable across migration and future comments.
CREATE TABLE merge_discussion (
  id INTEGER PRIMARY KEY REFERENCES merge_activity(id) ON DELETE CASCADE,
  merge_request_id INTEGER NOT NULL REFERENCES merge_request(id) ON DELETE CASCADE,
  author_id INTEGER REFERENCES "user"(id) ON DELETE RESTRICT,
  version INTEGER NOT NULL,
  resolved INTEGER NOT NULL DEFAULT 0 CHECK (resolved IN (0, 1)),
  state_version INTEGER NOT NULL DEFAULT 1 CHECK (state_version > 0),
  state_actor_id INTEGER REFERENCES "user"(id) ON DELETE RESTRICT,
  state_changed_at TEXT,
  UNIQUE (merge_request_id, id)
);
ALTER TABLE merge_activity ADD COLUMN discussion_id INTEGER REFERENCES merge_discussion(id) ON DELETE CASCADE;
CREATE INDEX merge_discussion_request ON merge_discussion(merge_request_id, resolved, id);
CREATE INDEX merge_activity_discussion ON merge_activity(discussion_id, id);
INSERT INTO merge_discussion(id, merge_request_id, author_id, version)
SELECT id, merge_request_id, actor_id, version FROM merge_activity
WHERE kind IN ('comment', 'comment_deleted')
   OR (kind IN ('approved', 'changes_requested', 'withdrawn') AND trim(body) <> '');
UPDATE merge_activity SET discussion_id = id WHERE id IN (SELECT id FROM merge_discussion);

CREATE TRIGGER merge_discussion_root AFTER INSERT ON merge_activity
WHEN NEW.discussion_id IS NULL AND (NEW.kind = 'comment'
  OR (NEW.kind IN ('approved', 'changes_requested', 'withdrawn') AND trim(NEW.body) <> '')) BEGIN
  INSERT INTO merge_discussion(id, merge_request_id, author_id, version)
    VALUES (NEW.id, NEW.merge_request_id, NEW.actor_id, NEW.version);
  UPDATE merge_activity SET discussion_id = NEW.id WHERE id = NEW.id;
END;
CREATE TRIGGER merge_discussion_reply_scope BEFORE INSERT ON merge_activity
WHEN NEW.discussion_id IS NOT NULL BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM merge_discussion d WHERE d.id = NEW.discussion_id
      AND d.merge_request_id = NEW.merge_request_id AND d.version = NEW.version
  ) THEN RAISE(ABORT, 'discussion does not belong to this merge request revision') END;
END;
CREATE TRIGGER merge_discussion_notifications AFTER UPDATE OF state_version ON merge_discussion
WHEN NEW.state_version <> OLD.state_version BEGIN
  INSERT INTO merge_activity(merge_request_id, actor_id, kind, version, discussion_id)
    VALUES (NEW.merge_request_id, NEW.state_actor_id,
      CASE WHEN NEW.resolved = 1 THEN 'discussion_resolved' ELSE 'discussion_reopened' END,
      NEW.version, NEW.id);
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, version)
    SELECT id, 'merge-discussion:' || NEW.id || ':' || NEW.state_version, NEW.state_actor_id,
      CASE WHEN NEW.resolved = 1 THEN 'discussion_resolved' ELSE 'discussion_reopened' END,
      NEW.version FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id;
END;
