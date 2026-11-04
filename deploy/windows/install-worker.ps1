# Run elevated while preparing a dedicated Windows Server 2022 x64 AMI, after
# installing SSM Agent, AWS CLI v2 and a Windows Docker Engine (Containers enabled).
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Bundle,
  [Parameter(Mandatory)][string]$RunnerImage
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Version.Build -ne 20348 -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Use Windows Server 2022 x64' }
$admin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated' }
if ((Get-Service AmazonSSMAgent).Status -ne 'Running') { throw 'SSM Agent must be running' }
& aws.exe --version
if ($LASTEXITCODE -ne 0) { throw 'Install AWS CLI v2' }
$info = & docker.exe info --format '{{json .}}' | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $info.OSType -ne 'windows' -or $info.Architecture -notin @('x86_64', 'amd64')) { throw 'A Windows x64 Docker daemon is required' }
& docker.exe pull $RunnerImage
if ($LASTEXITCODE -ne 0) { throw 'Pull the Windows task image first' }
$image = & docker.exe image inspect --format '{{json .}}' $RunnerImage | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $image.Os -ne 'windows' -or $image.Architecture -ne 'amd64' -or ([version]$image.OsVersion).Build -ne 20348) { throw 'Use a Windows Server 2022 x64 task image' }
$directory = 'C:\ProgramData\MoonHub'
New-Item -ItemType Directory -Force $directory | Out-Null
& icacls.exe $directory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Worker directory ACL failed' }
Copy-Item (Join-Path $Bundle 'bin') $directory -Recurse -Force
& "$directory\bin\moonhub-runner.exe" --help
if ($LASTEXITCODE -ne 0) { throw 'Runner executable verification failed' }
Write-Host 'Worker AMI prepared. Do not bake registration tokens, bootstrap files or controller state into it.'
