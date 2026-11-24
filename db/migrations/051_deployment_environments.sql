ALTER TABLE pipeline_secret_delivery ADD COLUMN source_environment_id INTEGER NOT NULL DEFAULT 0;
CREATE TABLE repository_deployment_environment (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
 name TEXT NOT NULL COLLATE NOCASE CHECK(length(name) BETWEEN 1 AND 100),
 version INTEGER NOT NULL DEFAULT 1 CHECK(version>0),
 reviewers_json TEXT NOT NULL CHECK(json_valid(reviewers_json) AND json_type(reviewers_json)='array' AND json_array_length(reviewers_json)<=16),
 UNIQUE(repository_id,name)
);
CREATE TABLE deployment_environment_variable (
 version INTEGER PRIMARY KEY AUTOINCREMENT,
 environment_id INTEGER NOT NULL REFERENCES repository_deployment_environment(id) ON DELETE CASCADE,
 name TEXT NOT NULL COLLATE NOCASE,
 value TEXT NOT NULL CHECK(length(CAST(value AS BLOB))<=49152),
 UNIQUE(environment_id,name)
);
CREATE TABLE deployment_environment_secret (
 version INTEGER PRIMARY KEY AUTOINCREMENT,
 environment_id INTEGER NOT NULL REFERENCES repository_deployment_environment(id) ON DELETE CASCADE,
 name TEXT NOT NULL COLLATE NOCASE,
 value TEXT NOT NULL CHECK(length(CAST(value AS BLOB)) BETWEEN 1 AND 16384),
 UNIQUE(environment_id,name)
);
CREATE TABLE pipeline_run_deployment_snapshot (
 run_id INTEGER PRIMARY KEY REFERENCES pipeline_run(id) ON DELETE CASCADE,
 data_json TEXT NOT NULL CHECK(json_valid(data_json) AND length(CAST(data_json AS BLOB))<=1048576)
);
CREATE TABLE pipeline_job_deployment (
 job_id INTEGER PRIMARY KEY REFERENCES pipeline_job(id) ON DELETE CASCADE,
 environment_id INTEGER NOT NULL,
 name TEXT NOT NULL,
 url TEXT NOT NULL,
 policy_version INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('pending','approved','rejected','cancelled')),
 variables_json TEXT NOT NULL CHECK(json_valid(variables_json) AND length(CAST(variables_json AS BLOB))<=262144)
);
CREATE TABLE pipeline_deployment_review (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 job_id INTEGER NOT NULL REFERENCES pipeline_job(id) ON DELETE CASCADE,
 environment_id INTEGER NOT NULL,
 policy_version INTEGER NOT NULL,
 actor_id INTEGER REFERENCES user(id) ON DELETE SET NULL,
 decision TEXT NOT NULL CHECK(decision IN ('approved','rejected','cancelled')),
 created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TRIGGER pipeline_deployment_snapshot_immutable BEFORE UPDATE ON pipeline_run_deployment_snapshot BEGIN SELECT RAISE(ABORT,'immutable deployment snapshot'); END;
CREATE TRIGGER pipeline_deployment_identity_immutable BEFORE UPDATE OF job_id,environment_id,name,url,variables_json ON pipeline_job_deployment BEGIN SELECT RAISE(ABORT,'immutable deployment identity'); END;
CREATE TRIGGER pipeline_deployment_review_immutable BEFORE UPDATE OF job_id,environment_id,policy_version,decision,created_at ON pipeline_deployment_review BEGIN SELECT RAISE(ABORT,'immutable deployment review'); END;
CREATE TRIGGER pipeline_deployment_cancelled AFTER UPDATE OF status ON pipeline_job WHEN NEW.status='completed' AND NEW.conclusion='cancelled' BEGIN
 INSERT INTO pipeline_deployment_review(job_id,environment_id,policy_version,decision) SELECT job_id,environment_id,policy_version,'cancelled' FROM pipeline_job_deployment WHERE job_id=NEW.id AND state='pending';
 UPDATE pipeline_job_deployment SET state='cancelled' WHERE job_id=NEW.id AND state='pending';
END;
CREATE VIEW pipeline_deployment_admission AS
 SELECT d.job_id FROM pipeline_job_deployment d JOIN repository_deployment_environment e ON e.id=d.environment_id JOIN pipeline_job j ON j.id=d.job_id JOIN pipeline_run r ON r.id=j.run_id
 WHERE d.state='approved' AND d.policy_version=e.version AND e.repository_id=r.repository_id
 AND (json_array_length(e.reviewers_json)=0 OR EXISTS (
   SELECT 1 FROM pipeline_deployment_review v JOIN user u ON u.id=v.actor_id JOIN repository repo ON repo.id=r.repository_id LEFT JOIN team_member tm ON tm.team_id=repo.team_id AND tm.user_id=u.id
   WHERE v.job_id=d.job_id AND v.environment_id=e.id AND v.policy_version=e.version AND v.decision='approved' AND u.status='active'
     AND (u.is_site_admin=1 OR tm.role IN ('owner','admin','member'))
     AND EXISTS (SELECT 1 FROM json_each(e.reviewers_json) reviewer WHERE reviewer.value=u.id)
 ));

CREATE INDEX pipeline_job_deployment_environment ON pipeline_job_deployment(environment_id,job_id);
CREATE INDEX pipeline_deployment_review_job ON pipeline_deployment_review(job_id,policy_version,id);
