# Build on Windows x64 with Visual Studio C++ Build Tools and the production
# MoonBit version on PATH. Output is both the worker installation and image input.
[CmdletBinding()]
param([string]$Output = '.tmp/windows-runner')
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess -or $env:OS -ne 'Windows_NT') { throw 'Build on Windows x64' }
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$pin = [regex]::Match((Get-Content deploy/base.Dockerfile -Raw), '(?m)^ARG MOONBIT_VERSION=(\S+)\r?$').Groups[1].Value
$actual = & moonc -v
if ($LASTEXITCODE -ne 0 -or ($actual -split '\s+')[0] -ne "v$pin") { throw "Expected MoonBit $pin; got $actual" }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio C++ Build Tools are required' }
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
& moon build --target native --strip -j 1 --deny-warn cmd/moonhub-runner
if ($LASTEXITCODE -ne 0) { throw 'Windows runner build failed' }
$outputRoot = [IO.Path]::GetFullPath($Output, $root)
if (Test-Path $outputRoot) { throw 'Output must be a new directory' }
New-Item -ItemType Directory -Path "$outputRoot/bin", "$outputRoot/actions", "$outputRoot/licenses" | Out-Null
Copy-Item '_build/native/debug/build/cmd/moonhub-runner/moonhub-runner.exe' "$outputRoot/bin/"
& cl.exe /nologo /W4 /WX /O2 /MT runner/step-launcher.c "/Fe:$outputRoot/bin/moonhub-runner-step.exe" "/Fo:$outputRoot/bin/step-launcher.obj"
if ($LASTEXITCODE -ne 0) { throw 'Windows launcher build failed' }
Remove-Item "$outputRoot/bin/step-launcher.obj"
# The MoonBit executable may use the dynamic MSVC runtime. Ship the redistributable
# DLLs beside it, not any development tools or a developer's environment/config.
$crt = Get-ChildItem "$env:VCToolsRedistDir/x64/Microsoft.VC*.CRT" -Directory | Select-Object -First 1
if (-not $crt) { throw 'MSVC x64 redistributable directory is missing' }
Copy-Item "$($crt.FullName)/*.dll" "$outputRoot/bin/"
& npm.cmd ci --prefix runner/actions --omit=dev --ignore-scripts --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw 'Action dependencies failed' }
Copy-Item runner/actions/*.mjs "$outputRoot/actions/"
Copy-Item runner/actions/node_modules "$outputRoot/actions/" -Recurse
Copy-Item LICENSE "$outputRoot/licenses/MoonHub.txt"
Copy-Item vendor/yaml/LICENSE "$outputRoot/licenses/yaml.txt"
Copy-Item deploy/windows/runtime.json "$outputRoot/runtime.json"
Copy-Item deploy/windows/install-worker.ps1, deploy/windows/install-provider.ps1, deploy/windows/run-provider.ps1 $outputRoot
$downloads = Join-Path $outputRoot '.downloads'
New-Item -ItemType Directory $downloads | Out-Null
try {
  $pins = Get-Content deploy/windows/runtime.json -Raw | ConvertFrom-Json
  foreach ($name in 'node24', 'node20', 'powershell', 'git') {
    $dependency = $pins.$name
    $archive = Join-Path $downloads ([IO.Path]::GetFileName($dependency.url))
    Invoke-WebRequest $dependency.url -OutFile $archive
    if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dependency.sha256) { throw "Checksum mismatch: $name" }
    switch ($name) {
      node24 {
        Expand-Archive $archive "$downloads/node24"
        $directory = Get-ChildItem "$downloads/node24" -Directory | Select-Object -First 1
        Copy-Item "$($directory.FullName)/*" "$outputRoot/bin/" -Recurse
      }
      node20 {
        Expand-Archive $archive "$downloads/node20"
        $directory = Get-ChildItem "$downloads/node20" -Directory | Select-Object -First 1
        Copy-Item "$($directory.FullName)/node.exe" "$outputRoot/bin/node20.exe"
      }
      powershell { Expand-Archive $archive "$outputRoot/pwsh" }
      git {
        & $archive -y "-o$outputRoot/git" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Portable Git extraction failed' }
      }
    }
  }
} finally { Remove-Item $downloads -Recurse -Force }
Write-Host "Windows runner bundle: $outputRoot"
