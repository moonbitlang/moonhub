const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const image = process.env.MOONHUB_RUNNER_IMAGE || 'registry.example/moonhub-runner@sha256:' + '0'.repeat(64);
const env = {
  ...process.env,
  MOONHUB_RUNNER_IMAGE: image,
  MOONHUB_PROVIDER_TOKEN_FILE: process.env.MOONHUB_PROVIDER_TOKEN_FILE || '/dev/null',
};
const config = JSON.parse(execFileSync('docker', [
  'compose', '-f', 'compose.yaml', '-f', 'deploy/compose.pipeline.yaml',
  'config', '--format', 'json',
], { cwd: root, env, encoding: 'utf8' }));
const services = config.services;
assert.ok(services.web);
assert.ok(services['pipeline-provider']);
assert.ok(services['pipeline-docker']);

const provider = services['pipeline-provider'];
const dind = services['pipeline-docker'];
const web = services.web;
assert.equal(dind.privileged, true, 'only the DinD service may be privileged');
assert.notEqual(provider.privileged, true, 'provider must not be privileged');
assert.ok(provider.build && provider.build.target === 'provider');
assert.equal(provider.environment.DOCKER_HOST, 'unix:///run/moonhub-docker/docker.sock');
assert.equal(provider.environment.MOONHUB_RUNNER_NETWORK, 'bridge');
assert.equal(provider.environment.MOONHUB_RUNNER_MEMORY, process.env.MOONHUB_RUNNER_MEMORY || '512m');
assert.equal(provider.environment.MOONHUB_RUNNER_CPUS, process.env.MOONHUB_RUNNER_CPUS || '1');
assert.equal(provider.environment.MOONHUB_RUNNER_PIDS_LIMIT, process.env.MOONHUB_RUNNER_PIDS_LIMIT || '256');
assert.ok(!provider.ports);
assert.ok(!dind.ports);
assert.ok(provider.secrets.some(secret => secret.target === '/run/secrets/provider_token'));
assert.ok(provider.volumes.some(volume => volume.target === '/var/lib/moonhub/provider'));
assert.ok(dind.volumes.some(volume => volume.target === '/var/lib/moonhub/provider'));
assert.ok(!provider.volumes.some(volume => volume.source === '/var/run/docker.sock'));
assert.ok(!dind.volumes.some(volume => volume.source === '/var/run/docker.sock'));
assert.ok(dind.entrypoint == null, 'retain the official DinD initialization');
assert.equal(dind.command[0], 'dockerd', 'skip automatic TCP listener arguments');
assert.ok(!dind.command.some(value => value.includes('tcp://')));
assert.ok(dind.command.includes('--host=unix:///run/moonhub-docker/docker.sock'));
assert.ok(provider.volumes.some(volume => volume.target === '/run/moonhub-docker'));
assert.ok(!web.volumes.some(volume => volume.target === '/run/moonhub-docker'));
assert.ok(web.networks.default !== undefined);
assert.ok(web.networks.pipeline);
assert.equal(provider.networks.pipeline.ipv4_address, '172.30.90.12');
assert.equal(dind.networks.pipeline.ipv4_address, '172.30.90.11');
assert.equal(web.networks.pipeline.ipv4_address, '172.30.90.10');
console.log('Pipeline deployment smoke passed: Compose isolation, secret mount, shared control volume, and privileged boundary verified.');
const oidc = JSON.parse(execFileSync('docker', [
  'compose', '-f', 'compose.yaml', '-f', 'deploy/compose.pipeline.yaml', '-f', 'deploy/compose.oidc.yaml',
  'config', '--format', 'json',
], { cwd: root, env: { ...env, MOONHUB_OIDC_CONFIG_FILE: '/private/operator/workflow-oidc.json' }, encoding: 'utf8' }));
assert.equal(oidc.services.web.environment.MOONHUB_OIDC_CONFIG, '/run/secrets/workflow_oidc');
const oidcMount = oidc.services.web.volumes.find(v => v.target === '/run/secrets/workflow_oidc');
assert.equal(oidcMount.source, '/private/operator/workflow-oidc.json');
assert.equal(oidcMount.read_only, true);
assert.equal(oidcMount.bind.create_host_path, false);
for (const name of ['ssh', 'pipeline-provider', 'pipeline-docker']) {
  assert.ok(!oidc.services[name].volumes.some(v => v.target === '/run/secrets/workflow_oidc'));
  assert.ok(!oidc.services[name].environment?.MOONHUB_OIDC_CONFIG);
}
console.log('Workflow OIDC Compose mount is read-only and restricted to Web.');
