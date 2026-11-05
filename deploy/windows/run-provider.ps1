# Scheduled-task entry point. Configuration and logs live in the private root.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Config)
$ErrorActionPreference = 'Stop'
try {
  $settings = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
  if ($settings.version -ne 1) { throw 'Unsupported provider installation configuration' }
  $directory = Split-Path ([IO.Path]::GetFullPath($Config)) -Parent
  $arguments = @('run', '--mode', 'docker', '--server', $settings.server, '--name', $settings.name,
    '--registration-token-file', "$directory\registration-token", '--state-dir', "$directory\controller",
    '--workspace-root', "$directory\workspace", '--runner-image', $settings.runner_image,
    '--docker', $settings.docker, '--docker-host', 'npipe:////./pipe/docker_engine')
  if ($settings.allow_http -eq $true) { $arguments += '--allow-http' }
  $log = Join-Path $directory 'provider.log'
  if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 10MB) {
    Move-Item -LiteralPath $log -Destination "$log.1" -Force
  }
  # Windows PowerShell treats native stderr as ErrorRecord; retain diagnostics
  # without turning routine native output into a terminating PowerShell error.
  $ErrorActionPreference = 'Continue'
  & "$directory\bin\moonhub-runner.exe" @arguments 2>&1 | Out-File -LiteralPath $log -Encoding utf8 -Append
  $code = $LASTEXITCODE
  if ($null -eq $code) { $code = 1 }
  exit $code
} catch {
  # Never print configuration or registration credentials on startup failure.
  [Console]::Error.WriteLine('MoonHub provider failed to start; inspect the private installation and task status.')
  exit 1
}
