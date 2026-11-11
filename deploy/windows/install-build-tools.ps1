[CmdletBinding()]
param([string]$Pins = "$PSScriptRoot/build-tools.json")
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$pin = Get-Content $Pins -Raw | ConvertFrom-Json
$downloads = 'C:/moonhub-build-downloads'
if (Test-Path $downloads) { throw 'Build Tools staging directory already exists' }
New-Item -ItemType Directory $downloads | Out-Null
try {
  foreach ($name in 'bootstrapper', 'channel') {
    $item = $pin.$name
    $filename = Join-Path $downloads (@{bootstrapper='vs_Setup.exe';channel='channel.chman'}[$name])
    Invoke-WebRequest $item.url -OutFile $filename -UseBasicParsing
    if ((Get-FileHash $filename -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.sha256) { throw "Build Tools checksum mismatch: $name" }
  }
  $setup = Join-Path $downloads 'vs_Setup.exe'
  $signature = Get-AuthenticodeSignature $setup
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=Microsoft Corporation[,;]') {
    throw 'Build Tools bootstrapper has no trusted Microsoft signature'
  }
  $arguments = @('--quiet','--wait','--norestart','--nocache',
    '--productId','Microsoft.VisualStudio.Product.BuildTools',
    '--channelId','VisualStudio.17.Release',
    '--channelUri',"$downloads/channel.chman",'--installChannelUri',"$downloads/channel.chman",
    '--installPath','C:/BuildTools')
  foreach ($component in $pin.components) { $arguments += @('--add', $component) }
  $process = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru
  if ($process.ExitCode -notin 0,3010) { throw "Build Tools installer failed: $($process.ExitCode)" }
  $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
  $installed = & $vswhere -products Microsoft.VisualStudio.Product.BuildTools -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or @($installed).Count -ne 1 -or $installed.installationVersion -ne $pin.visual_studio_version) {
    throw 'Installed Build Tools do not match the pinned C++ environment'
  }
  if (-not (Test-Path 'C:/BuildTools/Common7/Tools/VsDevCmd.bat')) { throw 'VsDevCmd is missing' }
  $sdk = Get-ChildItem "${env:ProgramFiles(x86)}/Windows Kits/10/Lib" -Directory | Where-Object Name -Like '10.0.26100.*'
  if (-not $sdk) { throw 'Windows SDK 26100 is missing' }
  Write-Host "Verified generic Windows C++ build environment: $($installed.installationVersion)"
} finally { Remove-Item $downloads -Recurse -Force }
