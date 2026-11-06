CREATE TABLE pipeline_job_output (
  id INTEGER PRIMARY KEY,
  job_id INTEGER NOT NULL UNIQUE REFERENCES pipeline_job(id) ON DELETE CASCADE,
  attempt_id INTEGER NOT NULL UNIQUE REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
  outputs_json TEXT NOT NULL
);
