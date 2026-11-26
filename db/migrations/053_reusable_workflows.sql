CREATE TABLE pipeline_call_expansion (
  job_id INTEGER PRIMARY KEY REFERENCES pipeline_job(id) ON DELETE CASCADE,
  inputs_json TEXT NOT NULL CHECK(json_valid(inputs_json) AND length(CAST(inputs_json AS BLOB)) <= 65535),
  cancel_requested INTEGER NOT NULL DEFAULT 0 CHECK(cancel_requested IN (0,1))
);
CREATE TRIGGER pipeline_call_expansion_immutable BEFORE UPDATE OF job_id,inputs_json ON pipeline_call_expansion BEGIN SELECT RAISE(ABORT,'immutable reusable inputs'); END;
CREATE TABLE pipeline_call_output (
  job_id INTEGER PRIMARY KEY REFERENCES pipeline_job(id) ON DELETE CASCADE,
  outputs_json TEXT NOT NULL CHECK(json_valid(outputs_json) AND length(CAST(outputs_json AS BLOB)) <= 32768)
);
CREATE TRIGGER pipeline_call_output_immutable BEFORE UPDATE ON pipeline_call_output BEGIN SELECT RAISE(ABORT,'immutable reusable outputs'); END;
-- Only hashes survive credential cleanup, including for failed-only reuse.
CREATE TABLE pipeline_call_secret_hash (
  public_run_id INTEGER NOT NULL REFERENCES pipeline_run(id) ON DELETE CASCADE,
  digest TEXT NOT NULL,
  units INTEGER NOT NULL CHECK(units BETWEEN 0 AND 16384),
  PRIMARY KEY(public_run_id,digest)
);
CREATE TRIGGER pipeline_call_secret_hash_immutable BEFORE UPDATE ON pipeline_call_secret_hash BEGIN SELECT RAISE(ABORT,'immutable secret fingerprint'); END;
