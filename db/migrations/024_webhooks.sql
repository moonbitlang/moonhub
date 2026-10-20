-- Transactional outbound events. Existing history is never replayed.
CREATE TABLE IF NOT EXISTS repository_webhook (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
 creator_id INTEGER NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
 url TEXT NOT NULL, secret TEXT NOT NULL, events TEXT NOT NULL,
 active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),
 version INTEGER NOT NULL DEFAULT 1,
 created_at TEXT NOT NULL DEFAULT(datetime('now'))
);
CREATE INDEX IF NOT EXISTS repository_webhook_repository ON repository_webhook(repository_id,id);
CREATE TABLE IF NOT EXISTS webhook_event (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
 event_key TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, payload TEXT NOT NULL,
 created_at TEXT NOT NULL DEFAULT(datetime('now'))
);
CREATE TABLE IF NOT EXISTS webhook_delivery (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 webhook_id INTEGER NOT NULL REFERENCES repository_webhook(id) ON DELETE CASCADE,
 event_id INTEGER NOT NULL REFERENCES webhook_event(id) ON DELETE CASCADE,
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','sending','succeeded','failed','cancelled')),
 attempts INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL DEFAULT 5,
 next_attempt_at TEXT NOT NULL DEFAULT(datetime('now')),
 lease TEXT, locked_at TEXT, response_code INTEGER NOT NULL DEFAULT 0,
 last_error TEXT NOT NULL DEFAULT '', completed_at TEXT,
 UNIQUE(webhook_id,event_id)
);
CREATE INDEX IF NOT EXISTS webhook_delivery_pending ON webhook_delivery(status,next_attempt_at,id);
CREATE TABLE IF NOT EXISTS webhook_attempt (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 delivery_id INTEGER NOT NULL REFERENCES webhook_delivery(id) ON DELETE CASCADE,
 attempt INTEGER NOT NULL, response_code INTEGER NOT NULL DEFAULT 0,
 error TEXT NOT NULL DEFAULT '', started_at TEXT NOT NULL DEFAULT(datetime('now')),
 completed_at TEXT, UNIQUE(delivery_id,attempt)
);
CREATE TABLE IF NOT EXISTS webhook_ref_intent (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
 actor_id INTEGER REFERENCES "user"(id) ON DELETE RESTRICT,
 deploy_key_id INTEGER REFERENCES repository_deploy_key(id) ON DELETE RESTRICT,
 source_key TEXT NOT NULL, reference TEXT NOT NULL, old_sha TEXT NOT NULL, new_sha TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('prepared','committed','ready','aborted')),
 created_at TEXT NOT NULL DEFAULT(datetime('now')),
 CHECK((actor_id IS NULL) <> (deploy_key_id IS NULL)),
 UNIQUE(repository_id,source_key,reference)
);
CREATE INDEX IF NOT EXISTS webhook_ref_intent_state ON webhook_ref_intent(state,id);
CREATE TRIGGER IF NOT EXISTS webhook_event_deliveries AFTER INSERT ON webhook_event BEGIN
 INSERT INTO webhook_delivery(webhook_id,event_id)
 SELECT h.id,NEW.id FROM repository_webhook h
 WHERE h.repository_id=NEW.repository_id AND h.active=1
 AND instr(',' || h.events || ',', ',' || NEW.kind || ',')>0;
END;

CREATE TRIGGER IF NOT EXISTS webhook_issue_activity AFTER INSERT ON issue_activity BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'issue:' || NEW.id,'issue',json_object('schema_version',1,'occurred_at',datetime('now'),'event','issue','action',NEW.kind,
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'issue',json_object('number',CAST(resource.number AS TEXT),'title',resource.title,'body',resource.description,'state',resource.status,'edit_version',CAST(resource.edit_version AS TEXT)),'activity',json_object('id',CAST(NEW.id AS TEXT),'body',NEW.body))
 FROM issue resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.actor_id
 WHERE resource.id=NEW.issue_id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER IF NOT EXISTS webhook_merge_activity AFTER INSERT ON merge_activity BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'mr:' || NEW.id,CASE WHEN NEW.kind IN ('approved','changes_requested','withdrawn') THEN 'review' ELSE 'merge_request' END,json_object('schema_version',1,'occurred_at',datetime('now'),'event',CASE WHEN NEW.kind IN ('approved','changes_requested','withdrawn') THEN 'review' ELSE 'merge_request' END,'action',NEW.kind,
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'merge_request',json_object('number',CAST(resource.number AS TEXT),'title',resource.title,'body',resource.description,'state',resource.status,'draft',json(CASE resource.draft WHEN 1 THEN 'true' ELSE 'false' END),'version',CAST(resource.current_version AS TEXT),'source_branch',resource.source_branch,'target_branch',resource.target_branch,'merged_sha',resource.merged_sha,'source_sha',(SELECT source_sha FROM merge_revision WHERE merge_request_id=resource.id AND version=NEW.version),'target_sha',(SELECT target_sha FROM merge_revision WHERE merge_request_id=resource.id AND version=NEW.version)),'activity',json_object('id',CAST(NEW.id AS TEXT),'body',NEW.body,'version',CAST(NEW.version AS TEXT),'discussion_id',CAST(COALESCE(NEW.discussion_id,CASE WHEN NEW.kind='comment' THEN NEW.id END) AS TEXT)))
 FROM merge_request resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.actor_id
 WHERE resource.id=NEW.merge_request_id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER IF NOT EXISTS webhook_review_request AFTER INSERT ON merge_review_request BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'review:' || NEW.merge_request_id || ':' || NEW.user_id || ':' || NEW.generation,'review',json_object('schema_version',1,'occurred_at',datetime('now'),'event','review','action','review_requested',
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'merge_request',json_object('number',CAST(resource.number AS TEXT),'version',CAST(NEW.version AS TEXT)),'reviewer_id',CAST(NEW.user_id AS TEXT))
 FROM merge_request resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.requested_by
 WHERE resource.id=NEW.merge_request_id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER IF NOT EXISTS webhook_review_rerequest AFTER UPDATE OF generation ON merge_review_request WHEN NEW.generation<>OLD.generation BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'review:' || NEW.merge_request_id || ':' || NEW.user_id || ':' || NEW.generation,'review',json_object('schema_version',1,'occurred_at',datetime('now'),'event','review','action','review_requested',
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'merge_request',json_object('number',CAST(resource.number AS TEXT),'version',CAST(NEW.version AS TEXT)),'reviewer_id',CAST(NEW.user_id AS TEXT))
 FROM merge_request resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.requested_by
 WHERE resource.id=NEW.merge_request_id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER IF NOT EXISTS webhook_pipeline_created AFTER INSERT ON pipeline_run BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'run:' || NEW.id || ':' || NEW.status || ':' || COALESCE(NEW.conclusion,''),'workflow_run',json_object('schema_version',1,'occurred_at',datetime('now'),'event','workflow_run','action',NEW.status,
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'run',json_object('number',CAST(resource.number AS TEXT),'workflow',resource.workflow_path,'branch',resource.source_branch,'sha',resource.commit_sha,'state',resource.status,'conclusion',resource.conclusion))
 FROM pipeline_run resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.requested_by_user_id
 WHERE resource.id=NEW.id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER IF NOT EXISTS webhook_pipeline_state AFTER UPDATE OF status,conclusion ON pipeline_run WHEN NEW.status<>OLD.status OR COALESCE(NEW.conclusion,'')<>COALESCE(OLD.conclusion,'') BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'run:' || NEW.id || ':' || NEW.status || ':' || COALESCE(NEW.conclusion,''),'workflow_run',json_object('schema_version',1,'occurred_at',datetime('now'),'event','workflow_run','action',NEW.status,
 'repository',json(json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name)),'sender',json(CASE WHEN u.id IS NULL THEN NULL ELSE json_object('id',CAST(u.id AS TEXT),'username',u.name_key) END),'run',json_object('number',CAST(resource.number AS TEXT),'workflow',resource.workflow_path,'branch',resource.source_branch,'sha',resource.commit_sha,'state',resource.status,'conclusion',resource.conclusion))
 FROM pipeline_run resource
 JOIN repository r ON r.id=resource.repository_id JOIN team t ON t.id=r.team_id
 LEFT JOIN "user" u ON u.id=NEW.requested_by_user_id
 WHERE resource.id=NEW.id
 AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;

CREATE TRIGGER IF NOT EXISTS webhook_ref_ready AFTER UPDATE OF state ON webhook_ref_intent
WHEN NEW.state='ready' AND OLD.state<>'ready' BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'push:' || NEW.id,'push',json_object('schema_version',1,'occurred_at',datetime('now'),'event','push',
 'action',CASE WHEN replace(NEW.new_sha,'0','')='' THEN 'deleted' WHEN replace(NEW.old_sha,'0','')='' THEN 'created' ELSE 'updated' END,
 'repository',json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name),
 'sender',json(CASE WHEN NEW.deploy_key_id IS NOT NULL THEN json_object('type','deploy_key','id',CAST(NEW.deploy_key_id AS TEXT)) ELSE json_object('type','user','id',CAST(u.id AS TEXT),'username',u.name_key) END),
 'ref',NEW.reference,'before',NEW.old_sha,'after',NEW.new_sha)
 FROM repository r JOIN team t ON t.id=r.team_id LEFT JOIN "user" u ON u.id=NEW.actor_id
 WHERE r.id=NEW.repository_id;
END;
CREATE TRIGGER IF NOT EXISTS webhook_merge_push AFTER INSERT ON merge_activity WHEN NEW.kind='merged' BEGIN
 INSERT INTO webhook_event(repository_id,event_key,kind,payload)
 SELECT r.id,'merge-push:' || NEW.id,'push',json_object('schema_version',1,'occurred_at',datetime('now'),'event','push','action','updated',
 'repository',json_object('id',CAST(r.id AS TEXT),'full_name',t.name_key || '/' || r.name),
 'sender',json_object('id',CAST(u.id AS TEXT),'username',u.name_key),
 'ref','refs/heads/' || m.target_branch,'before',v.target_sha,'after',m.merged_sha)
 FROM merge_request m JOIN merge_revision v ON v.merge_request_id=m.id AND v.version=NEW.version
 JOIN repository r ON r.id=m.repository_id JOIN team t ON t.id=r.team_id JOIN "user" u ON u.id=NEW.actor_id
 WHERE m.id=NEW.merge_request_id AND EXISTS(SELECT 1 FROM repository_webhook h WHERE h.repository_id=r.id AND h.active=1);
END;
-- Inline anchors are assigned after creating the discussion in the same transaction.
CREATE TRIGGER IF NOT EXISTS webhook_discussion_anchor AFTER UPDATE OF anchor ON merge_discussion
WHEN OLD.anchor IS NULL AND NEW.anchor IS NOT NULL BEGIN
 UPDATE webhook_event SET payload=json_set(payload,'$.activity.anchor',json(NEW.anchor))
 WHERE event_key='mr:' || NEW.id;
END;
