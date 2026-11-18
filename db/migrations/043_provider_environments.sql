ALTER TABLE pipeline_provider ADD COLUMN environment_protocol INTEGER NOT NULL DEFAULT 0;

CREATE TABLE pipeline_provider_environment (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  provider_id INTEGER NOT NULL REFERENCES pipeline_provider(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  environment_json TEXT NOT NULL CHECK (json_valid(environment_json)),
  labels_json TEXT NOT NULL CHECK (json_valid(labels_json)),
  is_default INTEGER NOT NULL CHECK (is_default IN (0,1)),
  UNIQUE (provider_id, name)
);

CREATE UNIQUE INDEX pipeline_provider_default_environment
  ON pipeline_provider_environment(provider_id) WHERE is_default=1;

CREATE TABLE pipeline_job_environment (
  job_id INTEGER PRIMARY KEY REFERENCES pipeline_job(id) ON DELETE CASCADE,
  environment_json TEXT NOT NULL CHECK (json_valid(environment_json))
);

CREATE TRIGGER pipeline_job_environment_immutable
BEFORE UPDATE ON pipeline_job_environment
BEGIN
  SELECT RAISE(ABORT, 'job execution environments are immutable');
END;

-- Keep queue diagnostics, capacity counts and claims on the same matching rule.
-- A profile supplies its own distribution/architecture labels; those labels
-- cannot leak in from the provider's legacy image declaration.
CREATE VIEW pipeline_provider_job_environment AS
SELECT p.id AS provider_id, j.id AS job_id, e.id AS environment_id,
  e.environment_json, e.is_default
FROM pipeline_provider p
JOIN pipeline_provider_environment e ON e.provider_id=p.id
CROSS JOIN pipeline_job j
LEFT JOIN pipeline_job_environment pinned ON pinned.job_id=j.id
WHERE NOT EXISTS (
  SELECT 1 FROM pipeline_job_label required WHERE required.job_id=j.id
  AND NOT EXISTS (SELECT 1 FROM json_each(e.labels_json) own WHERE own.value=required.label)
  AND NOT EXISTS (
    SELECT 1 FROM pipeline_provider_label shared
    WHERE shared.provider_id=p.id AND shared.label=required.label
      AND shared.label NOT LIKE 'ubuntu-%' AND shared.label NOT LIKE 'debian-%'
      AND shared.label NOT IN ('x64','arm64')
  )
)
AND (
  pinned.job_id IS NOT NULL OR e.is_default=1 OR EXISTS (
    SELECT 1 FROM pipeline_job_label required WHERE required.job_id=j.id
    AND NOT EXISTS (
      SELECT 1 FROM pipeline_provider_label shared
      WHERE shared.provider_id=p.id AND shared.label=required.label
        AND shared.label NOT LIKE 'ubuntu-%' AND shared.label NOT LIKE 'debian-%'
        AND shared.label NOT IN ('x64','arm64')
    )
  )
)
AND (
  pinned.job_id IS NULL OR (
    json_extract(pinned.environment_json,'$.image')=json_extract(e.environment_json,'$.image')
    AND json_extract(pinned.environment_json,'$.selector')=json_extract(e.environment_json,'$.selector')
    AND json_extract(pinned.environment_json,'$.architecture')=json_extract(e.environment_json,'$.architecture')
  )
)
UNION ALL
SELECT p.id, j.id, NULL, NULL, 1
FROM pipeline_provider p CROSS JOIN pipeline_job j
WHERE NOT EXISTS (SELECT 1 FROM pipeline_provider_environment e WHERE e.provider_id=p.id)
  AND NOT EXISTS (SELECT 1 FROM pipeline_job_environment pinned WHERE pinned.job_id=j.id)
  AND NOT EXISTS (
    SELECT 1 FROM pipeline_job_label required WHERE required.job_id=j.id
    AND NOT EXISTS (
      SELECT 1 FROM pipeline_provider_label own
      WHERE own.provider_id=p.id AND own.label=required.label
    )
  );
