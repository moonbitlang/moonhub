CREATE TABLE pipeline_workflow_event (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  actor_id INTEGER NOT NULL REFERENCES user(id),
  source_key TEXT NOT NULL,
  event_name TEXT NOT NULL CHECK(event_name IN ('workflow_run','repository_dispatch','pull_request')),
  branch TEXT NOT NULL,
  commit_sha TEXT,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json) AND length(CAST(payload_json AS BLOB)) <= 196608),
  depth INTEGER NOT NULL DEFAULT 0 CHECK(depth BETWEEN 0 AND 3),
  state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','processed')),
  retry_after INTEGER NOT NULL DEFAULT 0,
  last_error TEXT NOT NULL DEFAULT '',
  UNIQUE(repository_id,source_key)
);
CREATE INDEX pipeline_workflow_event_pending ON pipeline_workflow_event(state,retry_after,id);
CREATE TRIGGER pipeline_workflow_event_immutable BEFORE UPDATE OF repository_id,actor_id,source_key,event_name,branch,payload_json,depth ON pipeline_workflow_event
BEGIN SELECT RAISE(ABORT,'workflow events are immutable'); END;
CREATE TRIGGER pipeline_workflow_commit_immutable BEFORE UPDATE OF commit_sha ON pipeline_workflow_event
WHEN OLD.commit_sha IS NOT NULL
BEGIN SELECT RAISE(ABORT,'workflow event commits are immutable'); END;
ALTER TABLE pipeline_run ADD COLUMN workflow_event_id INTEGER REFERENCES pipeline_workflow_event(id);
CREATE UNIQUE INDEX pipeline_run_workflow_event_unique ON pipeline_run(workflow_event_id,workflow_path) WHERE workflow_event_id IS NOT NULL;
CREATE TRIGGER pipeline_run_workflow_event_immutable BEFORE UPDATE OF workflow_event_id ON pipeline_run
BEGIN SELECT RAISE(ABORT,'workflow event origins are immutable'); END;
ALTER TABLE repository_ref_event ADD COLUMN release_payload TEXT CHECK(release_payload IS NULL OR json_valid(release_payload));

-- Completion and its durable notification commit together. Each execution
-- attempt emits once; completion-driven chains stop after three downstream runs.
CREATE TRIGGER pipeline_completed_event AFTER UPDATE OF status ON pipeline_run
WHEN NEW.status='completed' AND OLD.status<>'completed'
BEGIN
  INSERT INTO pipeline_workflow_event(repository_id,actor_id,source_key,event_name,branch,payload_json,depth)
  SELECT NEW.repository_id,NEW.requested_by_user_id,'completed:'||NEW.id,'workflow_run',r.default_branch,
    json_object('action','completed','repository',json_object('full_name',t.name_key||'/'||r.name),
      'ref','refs/heads/'||r.default_branch,
      'workflow_run',json_object('id',COALESCE(NEW.public_run_id,NEW.id),'run_attempt',NEW.run_attempt,
        'record_number',NEW.number,'name',NEW.workflow_name,'path',NEW.workflow_path,
        'conclusion',NEW.conclusion,'head_branch',NEW.source_branch,'head_sha',NEW.commit_sha,'status','completed')),
    COALESCE(e.depth,0)+1
  FROM repository r JOIN team t ON t.id=r.team_id
  LEFT JOIN pipeline_workflow_event e ON e.id=NEW.workflow_event_id
  WHERE r.id=NEW.repository_id AND COALESCE(e.depth,0)<3;
END;

-- Lifecycle subscriptions do not become merge checks, so closing a PR cannot
-- cancel its own closed workflow or make that workflow a merging prerequisite.
CREATE TRIGGER pipeline_mr_lifecycle_event AFTER INSERT ON merge_activity
WHEN NEW.kind IN ('ready','edit','retargeted','close','merged') AND NEW.actor_id IS NOT NULL
BEGIN
  INSERT INTO pipeline_workflow_event(repository_id,actor_id,source_key,event_name,branch,commit_sha,payload_json)
  SELECT m.repository_id,NEW.actor_id,'mr-activity:'||NEW.id,'pull_request',m.source_branch,
    COALESCE(m.merged_sha,v.source_sha),
    json_object('action',CASE NEW.kind WHEN 'ready' THEN 'ready_for_review' WHEN 'close' THEN 'closed' WHEN 'merged' THEN 'closed' ELSE 'edited' END,
      'number',m.number,'ref',CASE WHEN m.status='merged' THEN 'refs/heads/'||m.target_branch ELSE 'refs/pull/'||m.number||'/merge' END,
      'repository',json_object('full_name',t.name_key||'/'||r.name),
      'pull_request',json_object('id',m.id,'number',m.number,'title',m.title,'body',m.description,
        'draft',json(CASE WHEN m.draft=1 THEN 'true' ELSE 'false' END),
        'merged',json(CASE WHEN m.status='merged' THEN 'true' ELSE 'false' END),
        'state',CASE WHEN m.status='open' THEN 'open' ELSE 'closed' END,
        'head',json_object('sha',v.source_sha,'ref',m.source_branch,'repo',json_object('full_name',t.name_key||'/'||r.name)),
        'base',json_object('sha',v.target_sha,'ref',m.target_branch,'repo',json_object('full_name',t.name_key||'/'||r.name))))
  FROM merge_request m JOIN merge_revision v ON v.merge_request_id=m.id AND v.version=m.current_version
  JOIN repository r ON r.id=m.repository_id JOIN team t ON t.id=r.team_id WHERE m.id=NEW.merge_request_id;
END;
