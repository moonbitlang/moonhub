DROP VIEW pipeline_provider_job_routing;

CREATE VIEW pipeline_provider_job_routing AS
SELECT candidate.*
FROM pipeline_provider_job_environment candidate
JOIN pipeline_provider p ON p.id = candidate.provider_id
WHERE CASE
  WHEN p.mode <> 'asg' THEN NOT EXISTS (
    SELECT 1 FROM pipeline_job_label
    WHERE job_id = candidate.job_id AND label IN ('windows-vm', 'macos-vm')
  )
  WHEN json_extract(p.config_json, '$.execution_mode') = 'windows-vm' THEN
    EXISTS (SELECT 1 FROM pipeline_job_label
      WHERE job_id = candidate.job_id AND label = 'windows')
    AND NOT EXISTS (SELECT 1 FROM pipeline_job_label
      WHERE job_id = candidate.job_id AND label = 'macos-vm')
    AND (
      json_extract(p.config_json, '$.windows_vm_default') = 'enabled'
      OR EXISTS (SELECT 1 FROM pipeline_job_label
        WHERE job_id = candidate.job_id AND label = 'windows-vm')
    )
  WHEN json_extract(p.config_json, '$.execution_mode') = 'macos-vm' THEN
    EXISTS (SELECT 1 FROM pipeline_job_label
      WHERE job_id = candidate.job_id AND label = 'macos')
    AND NOT EXISTS (SELECT 1 FROM pipeline_job_label
      WHERE job_id = candidate.job_id AND label IN ('linux', 'windows', 'windows-vm', 'x64', 'macos-14'))
  WHEN json_extract(p.config_json, '$.execution_mode') = 'linux-ci' THEN
    NOT EXISTS (SELECT 1 FROM pipeline_job_label
      WHERE job_id = candidate.job_id AND label IN ('windows', 'macos', 'windows-vm', 'macos-vm'))
  ELSE 0
END;
