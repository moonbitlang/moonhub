[CmdletBinding()]
param([string]$Bundle = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$pin = (Get-Content (Join-Path $Bundle 'runtime.json') -Raw | ConvertFrom-Json).vcredist
$installer = Join-Path $Bundle 'vc_redist.x64.exe'
if ((Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.sha256) {
  throw 'VC++ Redistributable checksum mismatch'
}

# A newer runtime can be supplied by the base image. Avoid the installer's
# downgrade error while still requiring at least our pinned version.
$key = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
$installed = Get-ItemProperty $key -ErrorAction SilentlyContinue
if (-not $installed -or $installed.Installed -ne 1 -or
    [version]($installed.Version -replace '^v', '') -lt [version]$pin.version) {
  $process = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
  if ($process.ExitCode -notin 0, 3010) {
    throw "VC++ Redistributable installation failed: $($process.ExitCode)"
  }
}

$installed = Get-ItemProperty $key
if ($installed.Installed -ne 1 -or
    [version]($installed.Version -replace '^v', '') -lt [version]$pin.version -or
    -not (Test-Path (Join-Path $env:SystemRoot 'System32/vcruntime140.dll'))) {
  throw 'The pinned x64 VC++ runtime is not installed system-wide'
}
Write-Host "Verified system x64 VC++ runtime: $($installed.Version)"
