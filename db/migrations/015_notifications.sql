ALTER TABLE merge_request ADD COLUMN reviews_poll_after INTEGER NOT NULL DEFAULT 0;
CREATE TABLE collaboration_thread (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  issue_id INTEGER UNIQUE REFERENCES issue(id) ON DELETE CASCADE,
  merge_request_id INTEGER UNIQUE REFERENCES merge_request(id) ON DELETE CASCADE,
  CHECK ((issue_id IS NULL) <> (merge_request_id IS NULL))
);
INSERT INTO collaboration_thread(repository_id, issue_id) SELECT repository_id, id FROM issue;
INSERT INTO collaboration_thread(repository_id, merge_request_id) SELECT repository_id, id FROM merge_request;
CREATE TRIGGER issue_notification_thread AFTER INSERT ON issue BEGIN
  INSERT INTO collaboration_thread(repository_id, issue_id) VALUES (NEW.repository_id, NEW.id);
END;
CREATE TRIGGER merge_notification_thread AFTER INSERT ON merge_request BEGIN
  INSERT INTO collaboration_thread(repository_id, merge_request_id) VALUES (NEW.repository_id, NEW.id);
END;

CREATE TABLE notification_subscription (
  thread_id INTEGER NOT NULL REFERENCES collaboration_thread(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  subscribed INTEGER NOT NULL DEFAULT 1 CHECK (subscribed IN (0, 1)),
  PRIMARY KEY (thread_id, user_id)
);
-- Preserve participation without replaying historical events on upgrade.
INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
SELECT t.id, i.author_id FROM collaboration_thread t JOIN issue i ON i.id = t.issue_id
UNION SELECT t.id, i.assignee_id FROM collaboration_thread t JOIN issue i ON i.id = t.issue_id WHERE i.assignee_id IS NOT NULL
UNION SELECT t.id, a.actor_id FROM collaboration_thread t JOIN issue_activity a ON a.issue_id = t.issue_id
UNION SELECT t.id, m.author_id FROM collaboration_thread t JOIN merge_request m ON m.id = t.merge_request_id
UNION SELECT t.id, a.actor_id FROM collaboration_thread t JOIN merge_activity a ON a.merge_request_id = t.merge_request_id WHERE a.actor_id IS NOT NULL;

CREATE TABLE notification_preferences (
  user_id INTEGER PRIMARY KEY REFERENCES "user"(id) ON DELETE CASCADE,
  email_enabled INTEGER NOT NULL DEFAULT 0 CHECK (email_enabled IN (0, 1))
);
CREATE TABLE merge_review_request (
  merge_request_id INTEGER NOT NULL REFERENCES merge_request(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  requested_by INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  version INTEGER NOT NULL,
  generation INTEGER NOT NULL DEFAULT 1,
  pending INTEGER NOT NULL DEFAULT 1 CHECK (pending IN (0, 1)),
  PRIMARY KEY (merge_request_id, user_id),
  FOREIGN KEY (merge_request_id, version) REFERENCES merge_revision(merge_request_id, version)
);
CREATE INDEX merge_review_request_user ON merge_review_request(user_id, pending, merge_request_id);
CREATE TABLE collaboration_event (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  thread_id INTEGER NOT NULL REFERENCES collaboration_thread(id) ON DELETE CASCADE,
  event_key TEXT NOT NULL UNIQUE,
  actor_id INTEGER REFERENCES "user"(id) ON DELETE SET NULL,
  kind TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 0,
  recipient_id INTEGER REFERENCES "user"(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE collaboration_notification (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id INTEGER NOT NULL REFERENCES collaboration_event(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  read_at TEXT,
  UNIQUE (event_id, user_id)
);
CREATE INDEX collaboration_notification_user ON collaboration_notification(user_id, read_at, id);
ALTER TABLE email_outbox ADD COLUMN notification_id INTEGER REFERENCES collaboration_notification(id) ON DELETE CASCADE;
CREATE UNIQUE INDEX email_outbox_notification ON email_outbox(notification_id) WHERE notification_id IS NOT NULL;

-- This view mirrors repository.can_access_repository(Read), including disabled
-- accounts, ready repositories, public visibility and site administrators.
CREATE VIEW collaboration_access AS
SELECT r.id AS repository_id, u.id AS user_id,
       (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin', 'member')) AS contributor
FROM repository r JOIN "user" u ON u.status = 'active'
LEFT JOIN team_member tm ON tm.team_id = r.team_id AND tm.user_id = u.id
WHERE r.ready = 1 AND (u.is_site_admin = 1 OR tm.role IN ('owner', 'admin', 'member') OR r.visibility = 'public');
CREATE VIEW collaboration_notification_visible AS
SELECT n.id, n.user_id, n.read_at, e.kind, e.version, e.created_at,
       e.actor_id, COALESCE(actor.display_name, 'Moonhub') AS actor,
       t.id AS thread_id, t.repository_id, t.issue_id, t.merge_request_id,
       owner.name_key AS owner, r.name AS repository_name,
       COALESCE(i.number, m.number) AS number, COALESCE(i.title, m.title) AS title
FROM collaboration_notification n JOIN collaboration_event e ON e.id = n.event_id
JOIN collaboration_thread t ON t.id = e.thread_id
JOIN collaboration_access access ON access.repository_id = t.repository_id AND access.user_id = n.user_id
JOIN repository r ON r.id = t.repository_id JOIN team owner ON owner.id = r.team_id
LEFT JOIN "user" actor ON actor.id = e.actor_id
LEFT JOIN issue i ON i.id = t.issue_id LEFT JOIN merge_request m ON m.id = t.merge_request_id;

-- Fan out once, atomically with the source event. Ordinary updates respect mute;
-- an explicit review request or assignment still reaches its named recipient.
CREATE TRIGGER collaboration_event_notifications AFTER INSERT ON collaboration_event BEGIN
  INSERT OR IGNORE INTO collaboration_notification(event_id, user_id)
  SELECT NEW.id, access.user_id FROM collaboration_thread t
  JOIN collaboration_access access ON access.repository_id = t.repository_id
  LEFT JOIN notification_subscription s ON s.thread_id = t.id AND s.user_id = access.user_id
  WHERE t.id = NEW.thread_id AND access.user_id <> COALESCE(NEW.actor_id, 0)
    AND ((NEW.recipient_id IS NOT NULL AND access.user_id = NEW.recipient_id)
      OR (NEW.recipient_id IS NULL AND s.subscribed = 1));
END;
CREATE TRIGGER collaboration_notification_email AFTER INSERT ON collaboration_notification BEGIN
  INSERT INTO email_outbox(notification_id, to_email, subject, body, template)
  SELECT NEW.id, u.email, 'Moonhub collaboration notification',
    'New activity: ' || v.kind || char(10) || '/' || v.owner || '/' || v.repository_name ||
    CASE WHEN v.issue_id IS NOT NULL THEN '/issues/' ELSE '/merge-requests/' END || v.number || char(10) ||
    'Open Moonhub to view this item. Manage email delivery in your Inbox settings.', 'collaboration_notification'
  FROM collaboration_notification_visible v JOIN "user" u ON u.id = v.user_id
  JOIN notification_preferences p ON p.user_id = u.id AND p.email_enabled = 1
  WHERE v.id = NEW.id AND u.email IS NOT NULL;
END;

CREATE TRIGGER issue_activity_notifications AFTER INSERT ON issue_activity BEGIN
  INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
    SELECT id, NEW.actor_id FROM collaboration_thread WHERE issue_id = NEW.issue_id;
  INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
    SELECT t.id, i.assignee_id FROM collaboration_thread t JOIN issue i ON i.id = t.issue_id
    WHERE i.id = NEW.issue_id AND i.assignee_id IS NOT NULL;
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, recipient_id)
    SELECT t.id, 'issue-activity:' || NEW.id, NEW.actor_id,
      CASE WHEN NEW.kind = 'opened' AND i.assignee_id IS NOT NULL THEN 'assigned' ELSE NEW.kind END,
      CASE WHEN NEW.kind IN ('opened', 'assigned') THEN i.assignee_id ELSE NULL END
    FROM collaboration_thread t JOIN issue i ON i.id = t.issue_id
    WHERE i.id = NEW.issue_id AND NEW.kind IN ('opened', 'assigned', 'comment', 'close', 'reopen');
END;
CREATE TRIGGER merge_activity_notifications AFTER INSERT ON merge_activity BEGIN
  INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
    SELECT id, NEW.actor_id FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id AND NEW.actor_id IS NOT NULL;
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, version)
    SELECT id, 'merge-activity:' || NEW.id, NEW.actor_id, NEW.kind, NEW.version
    FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id
      AND NEW.kind IN ('opened', 'comment', 'approved', 'changes_requested', 'withdrawn', 'merged', 'close', 'reopen', 'ready', 'updated');
  UPDATE merge_review_request SET pending = 0
    WHERE merge_request_id = NEW.merge_request_id AND user_id = NEW.actor_id AND version = NEW.version
      AND NEW.kind IN ('approved', 'changes_requested');
  UPDATE merge_review_request SET version = NEW.version, pending = 1
    WHERE merge_request_id = NEW.merge_request_id AND NEW.kind IN ('updated', 'ready', 'reopen');
  UPDATE merge_review_request SET pending = 1 WHERE merge_request_id = NEW.merge_request_id AND user_id = NEW.actor_id AND NEW.kind = 'withdrawn';
END;
CREATE TRIGGER merge_review_request_notifications AFTER INSERT ON merge_review_request BEGIN
  INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
    SELECT t.id, NEW.user_id FROM collaboration_thread t WHERE t.merge_request_id = NEW.merge_request_id
      AND NOT EXISTS (SELECT 1 FROM notification_subscription s WHERE s.thread_id = t.id AND s.user_id = NEW.user_id)
    UNION SELECT t.id, NEW.requested_by FROM collaboration_thread t WHERE t.merge_request_id = NEW.merge_request_id
      AND NOT EXISTS (SELECT 1 FROM notification_subscription s WHERE s.thread_id = t.id AND s.user_id = NEW.requested_by);
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, version, recipient_id)
    SELECT id, 'review-request:' || NEW.merge_request_id || ':' || NEW.user_id || ':' || NEW.generation,
      NEW.requested_by, 'review_requested', NEW.version, NEW.user_id
    FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id;
END;
CREATE TRIGGER merge_review_rerequest_notifications AFTER UPDATE OF generation ON merge_review_request
WHEN NEW.generation <> OLD.generation BEGIN
  INSERT OR IGNORE INTO notification_subscription(thread_id, user_id)
    SELECT t.id, NEW.user_id FROM collaboration_thread t WHERE t.merge_request_id = NEW.merge_request_id
      AND NOT EXISTS (SELECT 1 FROM notification_subscription s WHERE s.thread_id = t.id AND s.user_id = NEW.user_id)
    UNION SELECT t.id, NEW.requested_by FROM collaboration_thread t WHERE t.merge_request_id = NEW.merge_request_id
      AND NOT EXISTS (SELECT 1 FROM notification_subscription s WHERE s.thread_id = t.id AND s.user_id = NEW.requested_by);
  INSERT INTO collaboration_event(thread_id, event_key, actor_id, kind, version, recipient_id)
    SELECT id, 'review-request:' || NEW.merge_request_id || ':' || NEW.user_id || ':' || NEW.generation,
      NEW.requested_by, 'review_requested', NEW.version, NEW.user_id
    FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id;
END;
CREATE TRIGGER merge_check_waiting_notification AFTER INSERT ON merge_check
WHEN NEW.state = 'awaiting_approval' BEGIN
  INSERT OR IGNORE INTO collaboration_event(thread_id, event_key, kind, version)
    SELECT id, 'check:' || NEW.id || ':approval', 'checks_awaiting_approval', NEW.version
    FROM collaboration_thread WHERE merge_request_id = NEW.merge_request_id;
END;
CREATE TRIGGER merge_check_failure_notification AFTER UPDATE OF state, conclusion ON merge_check
WHEN NEW.state IN ('completed', 'error') AND (NEW.state <> OLD.state OR NEW.conclusion <> OLD.conclusion)
  AND NEW.conclusion <> 'success' BEGIN
  INSERT OR IGNORE INTO collaboration_event(thread_id, event_key, kind, version)
    SELECT t.id, 'check:' || NEW.id || ':' || COALESCE(NEW.run_number, 0) || ':' || NEW.state || ':' || NEW.conclusion,
      'checks_failed', NEW.version FROM collaboration_thread t JOIN merge_request m ON m.id = t.merge_request_id
    WHERE m.id = NEW.merge_request_id AND m.status = 'open' AND m.draft = 0
      AND m.current_version = NEW.version AND m.check_generation = NEW.generation;
END;
