# Prepare a dedicated Windows host or AMI. No AWS tooling is required here.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Bundle,
  [Parameter(Mandatory)][string]$RunnerImage,
  [string]$Directory = 'C:\ProgramData\MoonHub'
)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Use Windows x64' }
$admin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated' }
$hostOS = Get-CimInstance Win32_OperatingSystem
$build = [int]$hostOS.BuildNumber
$isolation = if ($hostOS.ProductType -eq 1 -and $build -ge 22000) {
  'hyperv'
} elseif ($hostOS.ProductType -ne 1 -and $build -eq 20348) {
  'process'
} else { throw 'Use Windows 11 x64 or Windows Server 2022 x64' }
# Pin the local Windows engine; do not inherit a developer's remote/Linux context.
$docker = (Get-Command docker.exe -CommandType Application -ErrorAction Stop).Source
$endpoint = 'npipe:////./pipe/docker_engine'
$info = & $docker --host $endpoint info --format '{{json .}}' | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $info.OSType -ne 'windows' -or $info.Architecture -notin @('x86_64', 'amd64')) { throw 'Switch the local Docker engine to Windows containers' }
$Bundle = [IO.Path]::GetFullPath($Bundle)
$Directory = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
if ($Directory -eq $Bundle -or $Directory.StartsWith($Bundle.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $Bundle.StartsWith($Directory + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Bundle and installation directories must be separate' }
if (-not [IO.Path]::IsPathRooted($Directory) -or $Directory -match '[",\r\n]' -or $Directory -eq [IO.Path]::GetPathRoot($Directory)) { throw 'Use an absolute private installation directory' }
foreach ($binary in 'moonhub-runner.exe', 'moonhub-runner-step.exe') {
  if (-not (Test-Path -LiteralPath (Join-Path $Bundle "bin/$binary") -PathType Leaf)) { throw "Missing bundle binary: $binary" }
}
. "$PSScriptRoot/installation-path.ps1"
Assert-MoonHubInstallationPath -Directory $Directory
if ((Test-Path -LiteralPath $Directory) -and @(Get-ChildItem -LiteralPath $Directory -Force).Count -gt 0 -and
    -not (Test-Path -LiteralPath (Join-Path $Directory 'bin/moonhub-runner.exe'))) { throw 'Refusing to reuse a non-MoonHub installation directory' }
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$imageJson = & $docker --host $endpoint image inspect --format '{{json .}}' $RunnerImage 2>$null
$inspectCode = $LASTEXITCODE
$ErrorActionPreference = $previousPreference
if ($inspectCode -ne 0) {
  & $docker --host $endpoint pull $RunnerImage
  if ($LASTEXITCODE -ne 0) { throw 'Pull the Windows task image first' }
  $imageJson = & $docker --host $endpoint image inspect --format '{{json .}}' $RunnerImage
}
$image = $imageJson | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $image.Os -ne 'windows' -or $image.Architecture -ne 'amd64' -or ([version]$image.OsVersion).Build -ne 20348) { throw 'Use a Windows Server 2022 x64 task image' }
$probe = 'moonhub-pipeline-install-' + [guid]::NewGuid().ToString('N')
try {
  & $docker --host $endpoint run --rm --name $probe --isolation $isolation --network none --user ContainerUser --memory 2048m --cpu-count 1 --entrypoint cmd.exe $RunnerImage /d /s /c 'exit /b 0'
  if ($LASTEXITCODE -ne 0) { throw 'Windows container preflight failed; enable Hyper-V/Containers and restart Windows if required' }
} finally {
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & $docker --host $endpoint rm -f $probe 2>&1 | Out-Null
  $ErrorActionPreference = $previousPreference
  $remaining = & $docker --host $endpoint ps -aq --filter "name=^$probe`$"
  if ($LASTEXITCODE -ne 0 -or $remaining) { throw 'Preflight container cleanup failed' }
}
# Remove inherited and explicit unprivileged grants, including on old files.
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
if (Test-Path -LiteralPath $Directory) {
  Assert-MoonHubInstallationPath -Directory $Directory
  Set-Acl -LiteralPath $Directory -AclObject $acl
} else {
  # Supply the private ACL at creation: no permissive interval between mkdir
  # and Set-Acl, and an attacker-created path is validated instead of trusted.
  $newDirectory = [IO.DirectoryInfo]::new($Directory)
  if ($PSVersionTable.PSEdition -eq 'Core') {
    [IO.FileSystemAclExtensions]::Create($newDirectory, $acl)
  } else {
    $newDirectory.Create($acl)
  }
}
Assert-MoonHubInstallationPath -Directory $Directory
# /reset replaces old explicit grants with the now-private inherited ACL.
if (@(Get-ChildItem -LiteralPath $Directory -Force).Count -gt 0) {
  & icacls.exe "$Directory\*" /reset /T /Q | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Worker directory ACL failed' }
}
Copy-Item -LiteralPath (Join-Path $Bundle 'bin') -Destination $Directory -Recurse -Force
& "$Directory\bin\moonhub-runner.exe" --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Runner executable verification failed' }
Write-Host "Windows worker installed ($isolation isolation). Keep credentials and provider state out of reusable images."
