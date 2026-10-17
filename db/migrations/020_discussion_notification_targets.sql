ALTER TABLE collaboration_event ADD COLUMN discussion_id INTEGER REFERENCES merge_discussion(id) ON DELETE CASCADE;
ALTER TABLE collaboration_event ADD COLUMN comment_id INTEGER REFERENCES merge_activity(id) ON DELETE CASCADE;

-- Backfill existing events without inserting events or replaying notification delivery.
UPDATE collaboration_event SET
  discussion_id = (SELECT a.discussion_id FROM merge_activity a
    JOIN collaboration_thread t ON t.merge_request_id = a.merge_request_id
    WHERE t.id = collaboration_event.thread_id AND collaboration_event.event_key = 'merge-activity:' || a.id),
  comment_id = (SELECT a.id FROM merge_activity a
    JOIN collaboration_thread t ON t.merge_request_id = a.merge_request_id
    WHERE t.id = collaboration_event.thread_id AND collaboration_event.event_key = 'merge-activity:' || a.id
      AND a.discussion_id IS NOT NULL)
WHERE event_key LIKE 'merge-activity:%';
UPDATE collaboration_event SET discussion_id = (
  SELECT d.id FROM merge_discussion d JOIN collaboration_thread t ON t.merge_request_id = d.merge_request_id
  WHERE t.id = collaboration_event.thread_id AND collaboration_event.event_key LIKE 'merge-discussion:' || d.id || ':%'
) WHERE event_key LIKE 'merge-discussion:%';

DROP VIEW collaboration_notification_visible;
CREATE VIEW collaboration_notification_visible AS
SELECT n.id, n.user_id, n.read_at, e.kind, e.version, e.created_at,
       e.actor_id, e.discussion_id, e.comment_id,
       COALESCE(actor.display_name, 'Moonhub') AS actor,
       t.id AS thread_id, t.repository_id, t.issue_id, t.merge_request_id,
       owner.name_key AS owner, r.name AS repository_name,
       COALESCE(i.number, m.number) AS number, COALESCE(i.title, m.title) AS title
FROM collaboration_notification n JOIN collaboration_event e ON e.id = n.event_id
JOIN collaboration_thread t ON t.id = e.thread_id
JOIN collaboration_access access ON access.repository_id = t.repository_id AND access.user_id = n.user_id
JOIN repository r ON r.id = t.repository_id JOIN team owner ON owner.id = r.team_id
LEFT JOIN "user" actor ON actor.id = e.actor_id
LEFT JOIN issue i ON i.id = t.issue_id LEFT JOIN merge_request m ON m.id = t.merge_request_id;

-- Future email deliveries use the same stable target as Inbox links. Existing
-- outbox messages are not rewritten or sent again during the upgrade.
DROP TRIGGER collaboration_notification_email;
CREATE TRIGGER collaboration_notification_email AFTER INSERT ON collaboration_notification BEGIN
  INSERT INTO email_outbox(notification_id, to_email, subject, body, template)
  SELECT NEW.id, u.email, 'Moonhub collaboration notification',
    'New activity: ' || v.kind || char(10) || '/' || v.owner || '/' || v.repository_name ||
    CASE WHEN v.issue_id IS NOT NULL THEN '/issues/' ELSE '/merge-requests/' END || v.number ||
    CASE WHEN v.discussion_id IS NOT NULL THEN '?discussion=' || v.discussion_id ||
      CASE WHEN v.comment_id IS NOT NULL THEN '&comment=' || v.comment_id || '#comment-' || v.comment_id
        ELSE '#discussion-' || v.discussion_id END
      ELSE '' END || char(10) ||
    'Open Moonhub to view this item. Manage email delivery in your Inbox settings.', 'collaboration_notification'
  FROM collaboration_notification_visible v JOIN "user" u ON u.id = v.user_id
  JOIN notification_preferences p ON p.user_id = u.id AND p.email_enabled = 1
  WHERE v.id = NEW.id AND u.email IS NOT NULL;
END;

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
      AND NEW.kind IN ('opened', 'comment', 'approved', 'changes_requested', 'withdrawn', 'merged', 'close', 'reopen', 'ready', 'updated');
  UPDATE merge_review_request SET pending = 0
    WHERE merge_request_id = NEW.merge_request_id AND user_id = NEW.actor_id AND version = NEW.version
      AND NEW.kind IN ('approved', 'changes_requested');
  UPDATE merge_review_request SET version = NEW.version, pending = 1
    WHERE merge_request_id = NEW.merge_request_id AND NEW.kind IN ('updated', 'ready', 'reopen');
  UPDATE merge_review_request SET pending = 1 WHERE merge_request_id = NEW.merge_request_id AND user_id = NEW.actor_id AND NEW.kind = 'withdrawn';
END;

DROP TRIGGER merge_discussion_notifications;
CREATE TRIGGER merge_discussion_notifications AFTER UPDATE OF state_version ON merge_discussion
WHEN NEW.state_version <> OLD.state_version BEGIN
  INSERT INTO merge_activity(merge_request_id, actor_id, kind, version, discussion_id)
    VALUES (NEW.merge_request_id, NEW.state_actor_id,
      CASE WHEN NEW.resolved = 1 THEN 'discussion_resolved' ELSE 'discussion_reopened' END,
      NEW.version, NEW.id);
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, version, discussion_id)
    SELECT id, 'merge-discussion:' || NEW.id || ':' || NEW.state_version, NEW.state_actor_id,
      CASE WHEN NEW.resolved = 1 THEN 'discussion_resolved' ELSE 'discussion_reopened' END,
      NEW.version, NEW.id FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id;
END;
