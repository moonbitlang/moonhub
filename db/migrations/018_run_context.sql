-- Historical runs have no complete context; do not infer it from live state.
ALTER TABLE pipeline_run ADD COLUMN context_json TEXT;
CREATE TRIGGER pipeline_run_context_immutable BEFORE UPDATE OF context_json ON pipeline_run
BEGIN
  SELECT RAISE(ABORT, 'pipeline run context is immutable');
END;
