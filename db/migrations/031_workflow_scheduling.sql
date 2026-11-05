-- Existing snapshots keep their independent scheduling behavior.
CREATE TABLE pipeline_run_schedule (
  run_id INTEGER PRIMARY KEY REFERENCES pipeline_run(id) ON DELETE CASCADE,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  group_key TEXT NOT NULL COLLATE NOCASE,
  admitted INTEGER NOT NULL CHECK (admitted IN (0, 1))
);
CREATE INDEX pipeline_concurrency_group ON pipeline_run_schedule(repository_id, group_key, admitted, run_id);
ALTER TABLE pipeline_job ADD COLUMN matrix_group TEXT NOT NULL DEFAULT '';
ALTER TABLE pipeline_job ADD COLUMN max_parallel INTEGER NOT NULL DEFAULT 256 CHECK (max_parallel BETWEEN 1 AND 256);
ALTER TABLE pipeline_job ADD COLUMN matrix_fail_fast INTEGER NOT NULL DEFAULT 0 CHECK (matrix_fail_fast IN (0,1));
CREATE INDEX pipeline_matrix_active ON pipeline_job(run_id, matrix_group, status);
