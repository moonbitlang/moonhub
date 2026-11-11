// Install the real MoonBit toolchain as ContainerUser, then remove the runner's
// bin directory from DLL lookup exactly as the upstream core installer does.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const { execFileSync, spawnSync } = require('node:child_process');

assert.equal(process.platform, 'win32');
const image = process.argv[2] || 'moonhub:runner-windows';
const version = fs.readFileSync('deploy/base.Dockerfile', 'utf8')
  .match(/^ARG MOONBIT_VERSION=(\d+\.\d+\.\d+\+[a-zA-Z0-9]+(?:-[a-zA-Z0-9]+)*)$/m)?.[1];
assert.ok(version, 'Missing production MoonBit pin');
const name = 'moonhub-moonbit-runtime-' + crypto.randomBytes(6).toString('hex');
const docker = ['--host', 'npipe:////./pipe/docker_engine'];
const script = String.raw`
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:MOONBIT_INSTALL_VERSION = '${version}'
$env:MOON_HOME = Join-Path $env:USERPROFILE '.moon'
$installer = Join-Path $env:TEMP 'install-moonbit.ps1'
Invoke-WebRequest https://cli.moonbitlang.com/install/powershell.ps1 -OutFile $installer
& $installer
if ($LASTEXITCODE -ne 0) { throw "MoonBit installation failed: $LASTEXITCODE" }

$project = Join-Path $env:USERPROFILE 'moonhub-core-probe'
New-Item -ItemType Directory $project | Out-Null
Set-Content (Join-Path $project 'moon.mod') 'name = "moonhub/core-probe"' -Encoding utf8NoBOM
Set-Content (Join-Path $project 'moon.pkg') 'pkgtype(kind: "executable")' -Encoding utf8NoBOM
Set-Content (Join-Path $project 'main.mbt') 'fn main { println("core-ready") }' -Encoding utf8NoBOM

# No adjacent CRT DLLs or runner PATH entry may help the downloaded moon.exe.
$moon = Join-Path $env:MOON_HOME 'bin/moon.exe'
$env:PATH = Split-Path $moon
& $moon version --all
if ($LASTEXITCODE -ne 0) { throw "MoonBit cannot start with restricted PATH: $LASTEXITCODE" }
foreach ($target in 'wasm', 'wasm-gc', 'js', 'native') {
  $core = Join-Path $env:MOON_HOME "lib/core/_build/$target/release/bundle/bigint/bigint.mi"
  if (-not (Test-Path $core)) { throw "MoonBit core bundle is missing: $core" }
}
& $moon -C $project check --target all --deny-warn
if ($LASTEXITCODE -ne 0) { throw "MoonBit core check failed: $LASTEXITCODE" }
$output = & $moon -C $project run --target wasm-gc .
if ($LASTEXITCODE -ne 0 -or "$output".Trim() -ne 'core-ready') {
  throw "MoonBit core build/run failed: $LASTEXITCODE, $output"
}
Write-Output 'MOONHUB_WINDOWS_MOONBIT_RUNTIME_OK'
`;

try {
  execFileSync('docker.exe', [...docker, 'run', '--isolation=process', '--name', name,
    '--entrypoint', 'C:/moonhub/pwsh/pwsh.exe', image,
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
  { stdio: 'inherit', timeout: 600000 });
} finally {
  const cleanup = spawnSync('docker.exe', [...docker, 'rm', '--force', name],
    { encoding: 'utf8', timeout: 30000 });
  if (cleanup.status !== 0 && !cleanup.stderr?.includes('No such container')) {
    throw new Error('Could not remove MoonBit smoke container: ' + (cleanup.error?.message || cleanup.stderr));
  }
}
