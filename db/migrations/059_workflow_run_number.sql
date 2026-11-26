ALTER TABLE pipeline_run ADD COLUMN workflow_run_number INTEGER CHECK(workflow_run_number > 0);

-- The public run sequence excludes reruns and is independent of the URL's
-- repository-wide attempt number. Rank retained historical original runs.
WITH original_runs AS MATERIALIZED (
  SELECT id, ROW_NUMBER() OVER (PARTITION BY repository_id, workflow_path ORDER BY number) AS run_number
  FROM pipeline_run
  WHERE public_run_id IS NULL
)
UPDATE pipeline_run
SET workflow_run_number = (
  SELECT run_number FROM original_runs WHERE id = COALESCE(pipeline_run.public_run_id, pipeline_run.id)
);

CREATE TABLE pipeline_workflow_run_sequence (
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  workflow_path TEXT NOT NULL,
  last_number INTEGER NOT NULL CHECK(last_number > 0),
  PRIMARY KEY(repository_id, workflow_path)
);
INSERT INTO pipeline_workflow_run_sequence(repository_id, workflow_path, last_number)
SELECT repository_id, workflow_path, MAX(workflow_run_number)
FROM pipeline_run
WHERE public_run_id IS NULL
GROUP BY repository_id, workflow_path;

CREATE TRIGGER pipeline_workflow_run_number_immutable BEFORE UPDATE OF workflow_run_number ON pipeline_run
BEGIN SELECT RAISE(ABORT,'workflow run number is immutable'); END;
