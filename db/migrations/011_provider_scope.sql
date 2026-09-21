ALTER TABLE pipeline_provider ADD COLUMN repository_scope TEXT NOT NULL DEFAULT 'selected'
  CHECK (repository_scope IN ('selected', 'all'));
ALTER TABLE pipeline_provider ADD COLUMN last_seen_ms INTEGER;
