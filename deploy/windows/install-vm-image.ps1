# Run on a clean Windows Server 2025 x64 AMI builder with AWS CLI and SSM Agent.
[CmdletBinding()]
param(
  [string]$Bundle = $PSScriptRoot,
  [switch]$BuildToolsInstalled
)
$ErrorActionPreference = 'Stop'
$os = Get-CimInstance Win32_OperatingSystem
if ($os.BuildNumber -ne '26100' -or $os.ProductType -ne 3 -or
    $env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -or
    (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name ContainerType -ErrorAction SilentlyContinue)) {
  throw 'The Windows VM image must be prepared on Server 2025 x64'
}
if ((Test-Path 'C:/moonhub') -or (Test-Path 'C:/ProgramData/MoonHub') -or
    (Get-LocalUser -Name 'MoonHubJob' -ErrorAction SilentlyContinue) -or
    (Get-ScheduledTask -TaskName 'MoonHubRunnerWorker' -ErrorAction SilentlyContinue)) {
  throw 'Start with a clean, unenrolled Windows instance'
}
Get-Command aws.exe -ErrorAction Stop | Out-Null
Get-Service AmazonSSMAgent -ErrorAction Stop | Out-Null
foreach ($file in @('bin/moonhub-runner.exe','bin/moonhub-runner-step.exe',
    'pwsh/pwsh.exe','git/cmd/git.exe','actions/runtime.mjs',
    'ci-host.ps1','install-vc-runtime.ps1','vc_redist.x64.exe')) {
  if (!(Test-Path (Join-Path $Bundle $file) -PathType Leaf)) {
    throw "Incomplete Windows bundle ($file)"
  }
}
Copy-Item $Bundle C:/moonhub -Recurse
& 'C:/moonhub/install-vc-runtime.ps1'
Remove-Item 'C:/moonhub/vc_redist.x64.exe'
Copy-Item 'C:/Windows/System32/tar.exe' 'C:/moonhub/bin/tar.exe'
if (!$BuildToolsInstalled) {
  & 'C:/moonhub/install-build-tools.ps1'
}
& 'C:/moonhub/bin/moonhub-runner.exe' execute --probe-environment
if ($LASTEXITCODE -ne 0) { throw 'The staged Windows runner could not start' }
