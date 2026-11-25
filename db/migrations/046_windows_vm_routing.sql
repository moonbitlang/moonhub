-- The administrator selector is only available on enrolled Windows VM
-- providers. A VM provider also accepts standard Windows jobs when enabled.
CREATE VIEW pipeline_provider_job_routing AS
SELECT candidate.*
FROM pipeline_provider_job_environment candidate
JOIN pipeline_provider p ON p.id = candidate.provider_id
WHERE (
  p.mode = 'asg' AND COALESCE(json_extract(p.config_json, '$.execution_mode'), '') = 'windows-vm'
  AND EXISTS (SELECT 1 FROM pipeline_job_label
    WHERE job_id = candidate.job_id AND label = 'windows')
  AND (
    json_extract(p.config_json, '$.windows_vm_default') = 'enabled'
    OR EXISTS (SELECT 1 FROM pipeline_job_label
      WHERE job_id = candidate.job_id AND label = 'windows-vm')
  )
) OR (
  COALESCE(json_extract(p.config_json, '$.execution_mode'), '') <> 'windows-vm'
  AND NOT EXISTS (SELECT 1 FROM pipeline_job_label
    WHERE job_id = candidate.job_id AND label = 'windows-vm')
);
