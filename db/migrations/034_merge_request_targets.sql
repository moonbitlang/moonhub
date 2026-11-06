ALTER TABLE merge_revision ADD COLUMN target_branch TEXT NOT NULL DEFAULT '';
UPDATE merge_revision SET target_branch = (
  SELECT target_branch FROM merge_request WHERE id = merge_revision.merge_request_id
);

DROP TRIGGER merge_activity_notifications;
CREATE TRIGGER merge_activity_notifications AFTER INSERT ON merge_activity BEGIN
  INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
    SELECT id, NEW.actor_id FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id AND NEW.actor_id IS NOT NULL;
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, version, discussion_id, comment_id)
    SELECT id, 'merge-activity:' || NEW.id, NEW.actor_id, NEW.kind, NEW.version,
      CASE WHEN NEW.discussion_id IS NOT NULL THEN NEW.discussion_id
        WHEN NEW.kind = 'comment' OR (NEW.kind IN ('approved', 'changes_requested', 'withdrawn') AND trim(NEW.body) <> '') THEN NEW.id
        ELSE NULL END,
      CASE WHEN NEW.discussion_id IS NOT NULL OR NEW.kind = 'comment'
        OR (NEW.kind IN ('approved', 'changes_requested', 'withdrawn') AND trim(NEW.body) <> '') THEN NEW.id ELSE NULL END
    FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id
      AND NEW.kind IN ('opened', 'comment', 'approved', 'changes_requested', 'withdrawn', 'merged', 'close', 'reopen', 'ready', 'updated', 'retargeted');
  UPDATE merge_review_request SET pending = 0
    WHERE merge_request_id = NEW.merge_request_id AND user_id = NEW.actor_id AND version = NEW.version
      AND NEW.kind IN ('approved', 'changes_requested');
  UPDATE merge_review_request SET version = NEW.version, pending = 1
    WHERE merge_request_id = NEW.merge_request_id AND NEW.kind IN ('updated', 'ready', 'reopen', 'retargeted');
  UPDATE merge_review_request SET pending = 1 WHERE merge_request_id = NEW.merge_request_id AND user_id = NEW.actor_id AND NEW.kind = 'withdrawn';
END;
