ALTER TABLE pipeline_artifact ADD COLUMN kind TEXT NOT NULL DEFAULT 'artifact' CHECK(kind IN ('artifact','cache'));
DROP INDEX pipeline_artifact_name;
CREATE UNIQUE INDEX pipeline_artifact_name ON pipeline_artifact(run_id,name) WHERE state <> 'deleted' AND kind='artifact';
CREATE TABLE pipeline_cache_scope (run_id INTEGER PRIMARY KEY REFERENCES pipeline_run(id) ON DELETE CASCADE, scope TEXT NOT NULL, base_scope TEXT NOT NULL, default_scope TEXT NOT NULL);
CREATE TRIGGER pipeline_cache_scope_immutable BEFORE UPDATE ON pipeline_cache_scope BEGIN SELECT RAISE(ABORT, 'pipeline cache scopes are immutable'); END;
CREATE TABLE pipeline_cache (artifact_id INTEGER PRIMARY KEY REFERENCES pipeline_artifact(id) ON DELETE CASCADE, repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE, scope TEXT NOT NULL, key TEXT NOT NULL, version TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','ready','deleted')), created_ms INTEGER NOT NULL, last_access_ms INTEGER NOT NULL);
CREATE UNIQUE INDEX pipeline_cache_key ON pipeline_cache(repository_id,scope,key,version) WHERE state <> 'deleted';
CREATE INDEX pipeline_cache_lookup ON pipeline_cache(repository_id,scope,version,state,created_ms);
CREATE INDEX pipeline_cache_eviction ON pipeline_cache(repository_id,state,last_access_ms);
