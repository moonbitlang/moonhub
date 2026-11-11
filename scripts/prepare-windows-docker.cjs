const {spawnSync} = require('node:child_process');
const {performance} = require('node:perf_hooks');
const endpoint = 'npipe:////./pipe/docker_engine';

async function prepareWindowsDocker({
  run = spawnSync,
  now = () => performance.now(),
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
  log = console.log,
  timeoutMs = 120000,
} = {}) {
  const deadline = now() + timeoutMs;
  let started = false, last = '';
  while (now() < deadline) {
    const probe = run('docker.exe', ['--host', endpoint, 'info', '--format', '{{json .}}'], {
      encoding: 'utf8', timeout: Math.max(1, Math.ceil(Math.min(10000, deadline - now()))), windowsHide: true,
    });
    if (!probe.error && probe.status === 0) {
      let info;
      try { info = JSON.parse(probe.stdout); } catch { throw new Error('Docker returned invalid platform information'); }
      if (info.OSType !== 'windows' || !['amd64', 'x86_64'].includes(info.Architecture)) {
        throw new Error('CI requires the local Windows x64 Docker daemon');
      }
      log('Windows Docker API is ready at ' + endpoint);
      return;
    }
    last = probe.error?.message || probe.stderr?.trim() || 'Docker API is unavailable';
    if (!started) {
      const service = run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
        "$ErrorActionPreference='Stop'; $service=Get-Service -Name docker; if($service.Status -ne 'Running'){Start-Service -Name docker}; Get-Service -Name docker | Format-Table Name,Status,StartType -AutoSize"], {
        encoding: 'utf8', timeout: Math.max(1, Math.ceil(Math.min(30000, deadline - now()))), windowsHide: true,
      });
      if (service.error || service.status !== 0) {
        throw new Error('Could not start the installed Windows Docker service: ' + (service.error?.message || service.stderr?.trim()));
      }
      started = true;
      log(service.stdout.trim());
      log('Waiting for the local Windows Docker API');
    }
    await sleep(Math.min(2000, Math.max(0, deadline - now())));
  }
  const diagnostics = run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    "Get-Service -Name docker,hns,vmcompute -ErrorAction SilentlyContinue | Format-Table Name,Status,StartType -AutoSize"], {
    encoding: 'utf8', timeout: 10000, windowsHide: true,
  });
  if (diagnostics.stdout) log(diagnostics.stdout.trim());
  throw new Error('Windows Docker API did not become ready within ' + timeoutMs + 'ms: ' + last);
}

module.exports = {prepareWindowsDocker};
if (require.main === module) {
  if (process.platform !== 'win32') throw new Error('Prepare Docker on Windows only');
  prepareWindowsDocker().catch(error => { console.error(error.message); process.exitCode = 1; });
}
