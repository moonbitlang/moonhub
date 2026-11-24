CREATE TABLE pipeline_attempt_report (
 attempt_id INTEGER PRIMARY KEY REFERENCES pipeline_job_attempt(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL CHECK(revision BETWEEN 1 AND 256),
 payload_hash TEXT NOT NULL,
 content_json TEXT NOT NULL CHECK(json_valid(content_json) AND length(CAST(content_json AS BLOB))<=4194304)
);
