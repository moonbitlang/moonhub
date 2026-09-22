const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const config = JSON.parse(execFileSync('docker', ['compose', '--env-file', '/dev/null', '-p', 'moonhub-shared-test',
  '-f', 'compose.yaml', '-f', 'deploy/compose.pipeline.yaml', '-f', 'deploy/compose.shared-host.yaml', 'config', '--format', 'json'], {
  cwd: path.resolve(__dirname, '..'), encoding: 'utf8', env: { ...process.env,
    MOONHUB_ROOT_PASSWORD_FILE: '/dev/null', MOONHUB_PROVIDER_TOKEN_FILE: '/dev/null', MOONHUB_RUNNER_IMAGE: 'moonhub-runner:test',
    MOONHUB_CGROUP_PARENT: 'moonhub.slice', MOONHUB_DIND_STORAGE_DIR: '/srv/moonhub/dind/docker' },
}));
let cpus = 0, memory = 0;
for (const service of Object.values(config.services)) {
  assert.equal(service.cgroup_parent, 'moonhub.slice');
  assert.ok(service.cpus > 0);
  assert.ok(service.mem_limit > 0);
  assert.equal(service.memswap_limit, service.mem_limit);
  assert.equal(service.logging.options['max-size'], '10m');
  cpus += Number(service.cpus);
  memory += Number(service.mem_limit);
}
assert.ok(cpus <= 4);
assert.ok(memory <= 8 * 1024 ** 3);
assert.equal(config.services['pipeline-provider'].scale, 1);
assert.equal(config.services['pipeline-docker'].cgroup, 'private');
assert.equal(config.volumes['pipeline-docker-data'].driver_opts.device, '/srv/moonhub/dind/docker');
const slice = fs.readFileSync(path.join(__dirname, '../deploy/moonhub.slice'), 'utf8');
assert.ok(slice.includes('CPUQuota=400%'));
assert.ok(slice.includes('MemoryMax=10G'));
console.log('Shared-host profile verified: aggregate budget, per-service limits, private cgroup namespace, single provider and bounded storage mapping.');
