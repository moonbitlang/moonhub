# Run elevated on a standalone Windows PC. One provider owns this Docker daemon.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Bundle,
  [Parameter(Mandatory)][string]$RunnerImage,
  [Parameter(Mandatory)][string]$Server,
  [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$Name,
  [string]$RegistrationTokenFile,
  [string]$Directory = 'C:\ProgramData\MoonHub',
  [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$TaskName = 'MoonHubRunnerProvider',
  [switch]$NoStart,
  [switch]$AllowHttp
)
$ErrorActionPreference = 'Stop'
$uri = $null
if (-not [Uri]::TryCreate($Server, [UriKind]::Absolute, [ref]$uri) -or
    $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or
    ($uri.Scheme -ne 'https' -and -not ($AllowHttp -and $uri.Scheme -eq 'http')) -or
    $Server -ne $uri.GetLeftPart([UriPartial]::Authority)) { throw 'Server must be an HTTPS origin; AllowHttp is only for local tests' }
if ($RunnerImage -notmatch '^\S{1,256}$' -or $RunnerImage.StartsWith('-')) { throw 'Invalid runner image' }
$Directory = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
if ($Directory -match '[",\r\n]' -or $Directory -eq [IO.Path]::GetPathRoot($Directory)) { throw 'Use an absolute private installation directory' }
. "$PSScriptRoot/installation-path.ps1"
Assert-MoonHubInstallationPath -Directory $Directory
# Keep installation identity immutable. Reinstallation may replace binaries but
# must not silently enroll another provider or reuse an ASG worker's state.
$configPath = Join-Path $Directory 'provider.json'
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing -and $existing.State -in @('Running', 'Queued')) { throw 'Drain the provider and stop its scheduled task before reinstalling' }
if ($existing -and -not (Test-Path -LiteralPath $configPath)) { throw 'Scheduled task belongs to another installation' }
if (Test-Path -LiteralPath (Join-Path $Directory 'private/bootstrap.json')) { throw 'Use a different directory from the ASG worker installation' }
if (Test-Path -LiteralPath $configPath) {
  $old = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  if ($old.version -ne 1 -or $old.server -ne $Server -or $old.name -ne $Name -or $old.task_name -ne $TaskName) { throw 'Installation belongs to another provider; preserve its private state and use a new directory' }
}
$registered = Test-Path -LiteralPath (Join-Path $Directory 'controller/registered.json')
if ($registered) {
  $binding = Get-Content -LiteralPath (Join-Path $Directory 'controller/registered.json') -Raw | ConvertFrom-Json
  if ($binding.server -ne $Server -or $binding.name -ne $Name -or $binding.mode -ne 'docker') { throw 'Controller state belongs to another provider' }
}
$token = $null
if (-not $registered -and -not (Test-Path -LiteralPath (Join-Path $Directory 'registration-token'))) {
  if (-not $RegistrationTokenFile -or (Get-Item -LiteralPath $RegistrationTokenFile).Length -gt 4096) { throw 'Supply the provider registration token file for initial enrollment' }
  $token = [IO.File]::ReadAllText([IO.Path]::GetFullPath($RegistrationTokenFile)).Trim()
  if ($token -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid registration credential file' }
}
& "$PSScriptRoot/install-worker.ps1" -Bundle $Bundle -RunnerImage $RunnerImage -Directory $Directory
Copy-Item -LiteralPath "$PSScriptRoot/run-provider.ps1" -Destination (Join-Path $Directory 'run-provider.ps1') -Force
if ($null -ne $token) { [IO.File]::WriteAllText((Join-Path $Directory 'registration-token'), $token, [Text.UTF8Encoding]::new($false)) }
$settings = [ordered]@{version=1;server=$Server;name=$Name;task_name=$TaskName;runner_image=$RunnerImage;docker=(Get-Command docker.exe -CommandType Application).Source;allow_http=[bool]$AllowHttp}
[IO.File]::WriteAllText($configPath, ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
# Paths cannot contain quotes; the task arguments contain paths only, never the
# registration token or provider credential. The runner receives values as argv.
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Directory\run-provider.ps1`" -Config `"$configPath`"" -WorkingDirectory $Directory
$taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -User 'SYSTEM' -RunLevel Highest -Settings $taskSettings -Description "MoonHub standalone Docker provider: $Name" -Force | Out-Null
if (-not $NoStart) { Start-ScheduledTask -TaskName $TaskName }
Write-Host "Standalone provider installed: $TaskName. Inspect $Directory\provider.log and the provider's execution settings."
