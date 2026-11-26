-- Expanded jobs and admission decisions are immutable run-attempt records.
ALTER TABLE pipeline_job ADD COLUMN actual_conclusion TEXT;
ALTER TABLE pipeline_job ADD COLUMN scheduling_error TEXT NOT NULL DEFAULT '';
ALTER TABLE pipeline_job ADD COLUMN allow_failure INTEGER NOT NULL DEFAULT 0 CHECK(allow_failure IN (0,1));
CREATE TABLE pipeline_job_definition (
  job_id INTEGER PRIMARY KEY REFERENCES pipeline_job(id) ON DELETE CASCADE,
  definition_json TEXT NOT NULL CHECK(json_valid(definition_json) AND length(CAST(definition_json AS BLOB)) <= 1048576)
);
CREATE TRIGGER pipeline_job_definition_immutable BEFORE UPDATE ON pipeline_job_definition BEGIN SELECT RAISE(ABORT,'immutable expanded job'); END;
CREATE TABLE pipeline_matrix_expansion (
  job_id INTEGER PRIMARY KEY REFERENCES pipeline_job(id) ON DELETE CASCADE,
  matrix_json TEXT NOT NULL CHECK(json_valid(matrix_json) AND length(CAST(matrix_json AS BLOB)) <= 65536)
);
CREATE TRIGGER pipeline_matrix_expansion_immutable BEFORE UPDATE ON pipeline_matrix_expansion BEGIN SELECT RAISE(ABORT,'immutable matrix expansion'); END;
CREATE TABLE pipeline_run_reuse_source (
  run_id INTEGER PRIMARY KEY REFERENCES pipeline_run(id) ON DELETE CASCADE,
  source_run_id INTEGER NOT NULL REFERENCES pipeline_run(id)
);
CREATE TRIGGER pipeline_run_reuse_source_immutable BEFORE UPDATE ON pipeline_run_reuse_source BEGIN SELECT RAISE(ABORT,'immutable reuse source'); END;
CREATE TABLE pipeline_concurrency_slot (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id INTEGER NOT NULL REFERENCES pipeline_run(id) ON DELETE CASCADE,
  job_id INTEGER UNIQUE REFERENCES pipeline_job(id) ON DELETE CASCADE,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  group_key TEXT NOT NULL COLLATE NOCASE CHECK(length(CAST(group_key AS BLOB)) BETWEEN 1 AND 256),
  admitted INTEGER NOT NULL CHECK(admitted IN (0,1))
);
CREATE UNIQUE INDEX pipeline_concurrency_run ON pipeline_concurrency_slot(run_id) WHERE job_id IS NULL;
CREATE INDEX pipeline_concurrency_pending ON pipeline_concurrency_slot(repository_id,group_key,admitted,id);
INSERT INTO pipeline_concurrency_slot(run_id,repository_id,group_key,admitted) SELECT run_id,repository_id,group_key,admitted FROM pipeline_run_schedule ORDER BY run_id;
DROP TABLE pipeline_run_schedule;
CREATE VIEW pipeline_run_schedule AS SELECT run_id,repository_id,group_key,admitted FROM pipeline_concurrency_slot WHERE job_id IS NULL;
CREATE VIEW pipeline_concurrency_live AS
  SELECT s.*,COALESCE(j.status,r.status) AS status,r.cancel_requested FROM pipeline_concurrency_slot s JOIN pipeline_run r ON r.id=s.run_id LEFT JOIN pipeline_job j ON j.id=s.job_id WHERE COALESCE(j.status,r.status)<>'completed';
