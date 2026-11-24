ALTER TABLE pipeline_run ADD COLUMN public_run_id INTEGER REFERENCES pipeline_run(id);
ALTER TABLE pipeline_run ADD COLUMN run_attempt INTEGER NOT NULL DEFAULT 1 CHECK(run_attempt > 0);
CREATE UNIQUE INDEX pipeline_run_attempt_unique ON pipeline_run(COALESCE(public_run_id,id),run_attempt);
CREATE TRIGGER pipeline_run_attempt_immutable BEFORE UPDATE OF public_run_id,run_attempt ON pipeline_run
BEGIN SELECT RAISE(ABORT,'run identity is immutable'); END;
CREATE TABLE pipeline_job_reuse (
  job_id INTEGER PRIMARY KEY REFERENCES pipeline_job(id) ON DELETE CASCADE,
  source_job_id INTEGER NOT NULL REFERENCES pipeline_job(id),
  CHECK(job_id <> source_job_id)
);
CREATE TRIGGER pipeline_job_reuse_immutable BEFORE UPDATE ON pipeline_job_reuse
BEGIN SELECT RAISE(ABORT,'reused job identity is immutable'); END;
