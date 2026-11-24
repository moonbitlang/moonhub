CREATE TABLE pipeline_check_run (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
 run_id INTEGER NOT NULL REFERENCES pipeline_run(id) ON DELETE CASCADE,
 attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
 writer_id INTEGER NOT NULL REFERENCES user(id),
 head_sha TEXT NOT NULL CHECK(length(head_sha)=40),
 name TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('queued','in_progress','completed')),
 conclusion TEXT NOT NULL DEFAULT '',
 output_json TEXT NOT NULL DEFAULT '{}',
 created_at TEXT NOT NULL DEFAULT (datetime('now')),
 updated_at TEXT NOT NULL DEFAULT (datetime('now')),
 CHECK((status='completed' AND conclusion IN ('success','failure','neutral','cancelled','skipped','timed_out','action_required')) OR (status<>'completed' AND conclusion=''))
);
CREATE INDEX pipeline_check_commit ON pipeline_check_run(repository_id,head_sha,run_id);
CREATE TRIGGER pipeline_check_identity BEFORE UPDATE OF repository_id,run_id,attempt_id,writer_id,head_sha,name ON pipeline_check_run BEGIN SELECT RAISE(ABORT,'immutable check identity'); END;
CREATE TABLE pipeline_artifact_api_capability (
 token_hash TEXT PRIMARY KEY,
 api_hash TEXT NOT NULL REFERENCES pipeline_api_runtime(token_hash) ON DELETE CASCADE,
 artifact_id INTEGER NOT NULL REFERENCES pipeline_artifact(id) ON DELETE CASCADE,
 expires_ms INTEGER NOT NULL
);
CREATE INDEX pipeline_artifact_api_expiry ON pipeline_artifact_api_capability(expires_ms);
ALTER TABLE branch_required_check ADD COLUMN whole_workflow INTEGER NOT NULL DEFAULT 1 CHECK(whole_workflow IN (0,1));
CREATE TABLE branch_required_result (
 repository_id INTEGER NOT NULL,
 branch TEXT NOT NULL,
 workflow_path TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('job','check')),
 name TEXT NOT NULL,
 PRIMARY KEY(repository_id,branch,workflow_path,kind,name),
 FOREIGN KEY(repository_id,branch,workflow_path) REFERENCES branch_required_check(repository_id,branch,workflow_path) ON DELETE CASCADE
);
