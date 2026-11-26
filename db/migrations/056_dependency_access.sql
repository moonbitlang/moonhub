CREATE TABLE pipeline_dependency_grant (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
 kind TEXT NOT NULL CHECK(kind IN ('github','moonhub')),
 target TEXT NOT NULL,
 reference TEXT NOT NULL,
 source_repository_id INTEGER REFERENCES repository(id) ON DELETE CASCADE,
 credential TEXT,
 version INTEGER NOT NULL CHECK(version>0),
 UNIQUE(repository_id,kind,target,reference),
 CHECK((kind='github' AND credential IS NOT NULL AND reference='' AND source_repository_id IS NULL) OR (kind='moonhub' AND credential IS NULL AND reference<>'' AND source_repository_id IS NOT NULL))
);
CREATE TABLE pipeline_dependency_runtime (
 token_hash TEXT PRIMARY KEY,
 attempt_id INTEGER NOT NULL REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
 execution_id TEXT NOT NULL,
 expires_ms INTEGER NOT NULL,
 requests INTEGER NOT NULL DEFAULT 0 CHECK(requests>=0)
);
CREATE INDEX pipeline_dependency_runtime_attempt ON pipeline_dependency_runtime(attempt_id);
CREATE TABLE pipeline_dependency_snapshot (
 public_run_id INTEGER NOT NULL REFERENCES pipeline_run(id) ON DELETE CASCADE,
 kind TEXT NOT NULL CHECK(kind IN ('github','moonhub')),
 target TEXT NOT NULL,
 reference TEXT NOT NULL,
 sha TEXT NOT NULL CHECK(length(sha)=40),
 PRIMARY KEY(public_run_id,kind,target,reference)
);
CREATE TRIGGER pipeline_dependency_snapshot_immutable BEFORE UPDATE ON pipeline_dependency_snapshot BEGIN SELECT RAISE(ABORT,'immutable dependency snapshot'); END;
