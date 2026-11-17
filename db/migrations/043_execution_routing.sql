-- Execution contracts are independent of provider backend and capacity purchase.
CREATE TABLE pipeline_execution_environment (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL,
  architecture TEXT NOT NULL CHECK (architecture IN ('x64','arm64')),
  environment_version TEXT NOT NULL,
  routing TEXT NOT NULL CHECK (routing IN ('restricted','linux-ci','adaptive')),
  restricted_provider_id INTEGER REFERENCES pipeline_provider(id) ON DELETE RESTRICT,
  linux_ci_provider_id INTEGER REFERENCES pipeline_provider(id) ON DELETE RESTRICT,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
  UNIQUE(label,architecture)
);
CREATE TABLE pipeline_execution_policy (
  repository_id INTEGER PRIMARY KEY REFERENCES repository(id) ON DELETE CASCADE,
  capability_retry INTEGER NOT NULL DEFAULT 0 CHECK (capability_retry IN (0,1)),
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0)
);
CREATE TABLE pipeline_job_execution (
  job_id INTEGER PRIMARY KEY REFERENCES pipeline_job(id) ON DELETE CASCADE,
  environment_id INTEGER NOT NULL REFERENCES pipeline_execution_environment(id) ON DELETE RESTRICT,
  environment_version TEXT NOT NULL,
  learning_key TEXT NOT NULL,
  trust_scope TEXT NOT NULL,
  routing TEXT NOT NULL CHECK (routing IN ('restricted','linux-ci','adaptive')),
  profile TEXT NOT NULL CHECK (profile IN ('restricted','linux-ci')),
  reason TEXT NOT NULL,
  retry_allowed INTEGER NOT NULL CHECK (retry_allowed IN (0,1)),
  retry_used INTEGER NOT NULL DEFAULT 0 CHECK (retry_used IN (0,1)),
  deadline_ms INTEGER,
  cleanup_worker_id INTEGER REFERENCES pipeline_worker(id) ON DELETE RESTRICT,
  cleanup_until_ms INTEGER
);
CREATE INDEX pipeline_job_execution_environment ON pipeline_job_execution(environment_id,profile,job_id);
CREATE TABLE pipeline_execution_learning (
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  learning_key TEXT NOT NULL,
  trust_scope TEXT NOT NULL,
  capability TEXT NOT NULL CHECK (capability IN ('docker','container-root','host-kernel')),
  updated_ms INTEGER NOT NULL,
  PRIMARY KEY(repository_id,learning_key,trust_scope,capability)
);
CREATE INDEX pipeline_execution_learning_age ON pipeline_execution_learning(repository_id,updated_ms);
CREATE TABLE pipeline_attempt_execution (
  attempt_id INTEGER PRIMARY KEY REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  profile TEXT NOT NULL CHECK (profile IN ('restricted','linux-ci')),
  reason TEXT NOT NULL,
  purchase_policy TEXT NOT NULL,
  failure_kind TEXT NOT NULL DEFAULT '' CHECK (failure_kind IN ('','missing_capability')),
  missing_capability TEXT NOT NULL DEFAULT '' CHECK (missing_capability IN ('','docker','container-root','host-kernel'))
);
