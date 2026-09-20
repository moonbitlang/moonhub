const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-dind-'));
const project = 'moonhub-dind-' + crypto.randomBytes(6).toString('hex');
const image = 'docker:27.5.1-dind';
const socket = 'unix:///run/moonhub-docker/docker.sock';
const env = {
  ...process.env,
  MOONHUB_RUNNER_IMAGE: image,
  MOONHUB_PROVIDER_TOKEN_FILE: '/dev/null',
  MOONHUB_ROOT_PASSWORD_FILE: '/dev/null',
  MOONHUB_PIPELINE_NETWORK: project,
  MOONHUB_PIPELINE_PREFIX: process.env.MOONHUB_DIND_SMOKE_PREFIX || '172.30.92',
};
const run = (args, options = {}) => execFileSync('docker', args, {
  cwd: root, env, encoding: 'utf8', timeout: 180000, maxBuffer: 4 * 1024 * 1024, ...options,
});
const compose = args => run(['compose', '--env-file', '/dev/null', '-p', project,
  '-f', 'compose.yaml', '-f', 'deploy/compose.pipeline.yaml', ...args]);
let daemon;
const inner = args => run(['exec', daemon, 'docker', '-H', socket, ...args]);
async function ready() {
  for (let n = 0; n < 60; n++) {
    try { inner(['info']); return; } catch { await new Promise(resolve => setTimeout(resolve, 1000)); }
  }
  throw new Error('DinD did not become ready');
}
function verify() {
  // Check listeners, not EXPOSE metadata (the upstream image declares TCP ports).
  const listeners = run(['exec', daemon, 'cat', '/proc/net/tcp', '/proc/net/tcp6']);
  assert.doesNotMatch(listeners, /\S+:(?:0947|0948)\s+\S+\s+0A\b/i);
  const name = 'limits-probe';
  inner(['create', '--name', name, '--user', '10001:10001', '--read-only',
    '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
    '--memory', '128m', '--cpus', '0.5', '--pids-limit', '32',
    '--entrypoint', '/bin/sh', image, '-ec', [
      'test "$(id -u)" = 10001',
      'test ! -e /run/moonhub-docker/docker.sock',
      'test ! -e /var/run/docker.sock',
      'test "$(cat /sys/fs/cgroup/memory.max)" = 134217728',
      'test "$(cat /sys/fs/cgroup/cpu.max)" = "50000 100000"',
      'test "$(cat /sys/fs/cgroup/pids.max)" = 32',
      'printf "CGROUP_LIMITS_OK\\n"',
    ].join('\n')]);
  try {
    const output = inner(['start', '-a', name]);
    const container = JSON.parse(inner(['inspect', name]))[0];
    assert.equal(container.State.ExitCode, 0, output);
    assert.ok(output.includes('CGROUP_LIMITS_OK'));
    assert.equal(container.HostConfig.Privileged, false);
    assert.equal(container.HostConfig.ReadonlyRootfs, true);
    assert.deepEqual(container.Mounts.filter(mount => mount.Type === 'bind'), []);
  } finally { inner(['rm', '-fv', name]); }
}
(async () => {
  try {
    compose(['up', '-d', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '90', 'pipeline-docker']);
    daemon = compose(['ps', '-q', 'pipeline-docker']).trim();
    assert.equal(inner(['info', '--format', '{{.CgroupVersion}}']).trim(), '2', 'this regression test requires cgroup v2');
    const archive = path.join(temporary, 'image.tar');
    run(['save', '-o', archive, image]);
    const input = fs.openSync(archive, 'r');
    try { run(['exec', '-i', daemon, 'docker', '-H', socket, 'load'], { stdio: [input, 'pipe', 'pipe'] }); }
    finally { fs.closeSync(input); }
    verify();
    compose(['restart', 'pipeline-docker']);
    await ready();
    verify();
    console.log('DinD smoke passed: CPU/memory/PID limits enforced before and after restart; no TCP listener.');
  } catch (error) {
    console.error(compose(['logs', '--tail', '60', 'pipeline-docker']));
    throw error;
  } finally {
    try { compose(['down', '--volumes', '--remove-orphans']); }
    finally { fs.rmSync(temporary, { recursive: true, force: true }); }
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
