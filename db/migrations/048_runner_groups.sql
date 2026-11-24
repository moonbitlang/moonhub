CREATE TABLE pipeline_runner_group (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0)
);
CREATE TABLE pipeline_runner_group_provider (
  group_id INTEGER NOT NULL REFERENCES pipeline_runner_group(id) ON DELETE CASCADE,
  provider_id INTEGER NOT NULL REFERENCES pipeline_provider(id) ON DELETE CASCADE,
  PRIMARY KEY (group_id, provider_id)
);
CREATE TABLE pipeline_runner_group_repository (
  group_id INTEGER NOT NULL REFERENCES pipeline_runner_group(id) ON DELETE CASCADE,
  repository_id INTEGER NOT NULL REFERENCES repository(id) ON DELETE CASCADE,
  PRIMARY KEY (group_id, repository_id)
);
CREATE TABLE pipeline_job_runner_group (
  job_id INTEGER PRIMARY KEY REFERENCES pipeline_job(id) ON DELETE CASCADE,
  group_name TEXT NOT NULL
);
CREATE TRIGGER pipeline_job_runner_group_immutable
BEFORE UPDATE ON pipeline_job_runner_group
BEGIN
  SELECT RAISE(ABORT, 'job runner groups are immutable');
END;

-- Authorization is an intersection: group membership, the repository grant,
-- existing provider scope and all labels must match. Keep one rule for claims,
-- capacity accounting, diagnostics and live attempt authorization.
CREATE VIEW pipeline_provider_job_group AS
SELECT p.id AS provider_id,j.id AS job_id
FROM pipeline_provider p CROSS JOIN pipeline_job j
JOIN pipeline_run r ON r.id=j.run_id
LEFT JOIN pipeline_job_runner_group required ON required.job_id=j.id
WHERE required.job_id IS NULL OR EXISTS (
  SELECT 1 FROM pipeline_runner_group g
  JOIN pipeline_runner_group_provider member ON member.group_id=g.id AND member.provider_id=p.id
  JOIN pipeline_runner_group_repository grant_ ON grant_.group_id=g.id AND grant_.repository_id=r.repository_id
  WHERE g.name=required.group_name
);

DROP VIEW pipeline_provider_job_environment;

CREATE VIEW pipeline_provider_job_environment AS
SELECT candidate.* FROM (
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
  )
) candidate JOIN pipeline_provider_job_group authorized
ON authorized.job_id=candidate.job_id AND authorized.provider_id=candidate.provider_id;

-- Group-only selectors bind the provider OS at claim time. Keep disposable
-- Windows VM opt-in and group grants in the same routing view used by claims,
-- capacity accounting and queue diagnostics.
DROP VIEW pipeline_provider_job_routing;

CREATE VIEW pipeline_provider_job_routing AS
SELECT candidate.*
FROM pipeline_provider_job_environment candidate
JOIN pipeline_provider p ON p.id = candidate.provider_id
WHERE (
  p.mode = 'asg' AND json_extract(p.config_json, '$.execution_mode') = 'windows-vm'
  AND (
    EXISTS (SELECT 1 FROM pipeline_job_label
      WHERE job_id = candidate.job_id AND label = 'windows')
    OR (
      EXISTS (SELECT 1 FROM pipeline_job_runner_group WHERE job_id = candidate.job_id)
      AND NOT EXISTS (SELECT 1 FROM pipeline_job_label
        WHERE job_id = candidate.job_id AND label IN ('linux', 'windows', 'macos'))
    )
  )
  AND (
    json_extract(p.config_json, '$.windows_vm_default') = 'enabled'
    OR EXISTS (SELECT 1 FROM pipeline_job_label
      WHERE job_id = candidate.job_id AND label = 'windows-vm')
  )
) OR (
  (
    p.mode <> 'asg'
    OR (
      json_extract(p.config_json, '$.execution_mode') = 'linux-ci'
      AND NOT EXISTS (SELECT 1 FROM pipeline_job_label
        WHERE job_id = candidate.job_id AND label IN ('windows', 'macos'))
    )
  )
  AND NOT EXISTS (SELECT 1 FROM pipeline_job_label
    WHERE job_id = candidate.job_id AND label = 'windows-vm')
);
