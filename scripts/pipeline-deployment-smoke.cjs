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
assert.match(provider.environment.DOCKER_HOST, /pipeline-docker:2375/);
assert.ok(!provider.ports);
assert.ok(!dind.ports);
assert.ok(provider.secrets.some(secret => secret.target === '/run/secrets/provider_token'));
assert.ok(provider.volumes.some(volume => volume.target === '/var/lib/moonhub/provider'));
assert.ok(dind.volumes.some(volume => volume.target === '/var/lib/moonhub/provider'));
assert.ok(!provider.volumes.some(volume => volume.source === '/var/run/docker.sock'));
assert.ok(!dind.volumes.some(volume => volume.source === '/var/run/docker.sock'));
assert.ok(dind.command.some(value => value.includes('tcp://0.0.0.0:2375')));
assert.ok(dind.command.some(value => value.includes('unix:///var/run/docker.sock')));
assert.ok(web.networks.default !== undefined);
assert.ok(web.networks.pipeline);
assert.equal(provider.networks.pipeline.ipv4_address, '172.30.90.12');
assert.equal(dind.networks.pipeline.ipv4_address, '172.30.90.11');
assert.equal(web.networks.pipeline.ipv4_address, '172.30.90.10');
console.log('Pipeline deployment smoke passed: Compose isolation, secret mount, shared control volume, and privileged boundary verified.');
