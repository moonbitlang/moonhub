const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { deploy } = require('./github-deploy.cjs');

const revision = 'a'.repeat(40);
const env = { GITHUB_SHA: revision, MOONHUB_DEPLOY_INSTANCE_ID: 'i-1234567890abcdef0', MOONHUB_DEPLOY_DOCUMENT: 'MoonHub-Deploy' };
const success = { Status: 'Success', StandardOutputContent: `MOONHUB_DEPLOY_OK:${revision}` };

test('SSM waits through eventual consistency and pending builds, using the pinned document and SHA', async () => {
  const calls = [];
  const replies = [new Error('not visible'), { Status: 'Pending' }, { Status: 'InProgress' }, success];
  replies[0].stderr = 'InvocationDoesNotExist';
  const result = await deploy({ env, sleep: async () => {}, log: () => {}, aws: args => {
    calls.push(args);
    if (args[1] === 'send-command') return { Command: { CommandId: 'command-1' } };
    const reply = replies.shift();
    if (reply instanceof Error) throw reply;
    return reply;
  } });
  assert.equal(result, success);
  assert.equal(calls.length, 5);
  assert.equal(calls[0][calls[0].indexOf('--document-version') + 1], '1');
  assert.deepEqual(JSON.parse(calls[0][calls[0].indexOf('--parameters') + 1]), { Revision: [revision] });
});

for (const reply of [{ Status: 'Failed', ResponseCode: 9 }, { Status: 'TimedOut' }, { Status: 'Success', StandardOutputContent: 'build started' }]) {
  test(`SSM propagates failure or missing verification: ${JSON.stringify(reply)}`, async () => {
    await assert.rejects(deploy({ env, sleep: async () => {}, log: () => {}, aws: args =>
      args[1] === 'send-command' ? { Command: { CommandId: 'command-1' } } : reply }));
  });
}

test('invalid inputs never send a production command', async () => {
  for (const extra of [{ GITHUB_SHA: 'master; id' }, { MOONHUB_DEPLOY_INSTANCE_ID: '' }, { MOONHUB_DEPLOY_DOCUMENT: 'AWS-RunShellScript' }]) {
    await assert.rejects(deploy({ env: { ...env, ...extra }, aws: () => assert.fail('called AWS') }));
  }
});

test('production wrapper deploys only clean, current fast-forward commits and verifies health', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-github-deploy-'));
  try {
    const source = path.join(root, 'source');
    const remote = path.join(root, 'remote');
    const bin = path.join(root, 'bin');
    fs.mkdirSync(source); fs.mkdirSync(bin); fs.mkdirSync(path.join(source, 'deploy'));
    const run = (command, args, cwd = source) => {
      const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr); return result.stdout.trim();
    };
    const git = (...args) => run('git', args);
    git('init', '-q', '-b', 'master');
    git('config', 'user.name', 'Test'); git('config', 'user.email', 'test@example.invalid');
    git('config', 'core.hooksPath', '/dev/null');
    fs.writeFileSync(path.join(source, '.gitignore'), 'deploy/production.env\n');
    fs.writeFileSync(path.join(source, 'deploy/production.sh'), '#!/bin/sh\necho "$1" >> "$TEST_CALLS"\nexit "${TEST_UPGRADE_FAIL:-0}"\n', { mode: 0o755 });
    git('add', '.'); git('commit', '-qm', 'initial');
    run('git', ['clone', '-q', '--bare', source, remote]);
    git('remote', 'add', 'origin', 'git@github.com:moonbitlang/moonhub.git');
    git('config', `url.${remote}.insteadOf`, 'git@github.com:moonbitlang/moonhub.git');
    const first = git('rev-parse', 'HEAD');
    fs.writeFileSync(path.join(source, 'deploy/production.env'), 'MOONHUB_COMPOSE_PROJECT_NAME=fixture\nMOONHUB_SERVER=https://example.invalid\n');
    const wrapper = path.join(root, 'deploy.sh');
    fs.writeFileSync(wrapper, fs.readFileSync(path.join(__dirname, '../deploy/github-deploy.sh'), 'utf8')
      .replaceAll('/run/lock/moonhub-github-deploy.lock', path.join(root, 'lock'))
      .replaceAll('/var/log/moonhub', path.join(root, 'logs'))
      .replaceAll('git@github.com:moonbitlang/moonhub.git', remote)
      .replaceAll('/srv/moonhub/source', source));
    for (const name of ['flock', 'curl']) fs.writeFileSync(path.join(bin, name), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    fs.writeFileSync(path.join(bin, 'docker'), '#!/bin/sh\ncase "$*" in *Health*) echo "${TEST_HEALTH:-healthy}" ;; *) echo "$TEST_REVISION" ;; esac\n', { mode: 0o755 });
    fs.writeFileSync(path.join(bin, 'systemctl'), '#!/bin/sh\necho active\n', { mode: 0o755 });
    const calls = path.join(root, 'calls');
    const check = (sha, extra = {}) => spawnSync('bash', [wrapper, sha], { encoding: 'utf8', env: {
      ...process.env, PATH: bin + ':' + process.env.PATH, TEST_CALLS: calls, TEST_REVISION: sha, ...extra,
    } });
    let result = check(first);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /MOONHUB_DEPLOY_OK:/);
    assert.equal(fs.readFileSync(calls, 'utf8'), 'upgrade\nstatus\n');
    result = check(first, { TEST_HEALTH: 'unhealthy' });
    assert.notEqual(result.status, 0); assert.doesNotMatch(result.stdout, /MOONHUB_DEPLOY_OK:/);
    result = check(first, { TEST_UPGRADE_FAIL: '9' });
    assert.equal(result.status, 9); assert.doesNotMatch(result.stdout, /MOONHUB_DEPLOY_OK:/);
    fs.writeFileSync(calls, '');
    fs.writeFileSync(path.join(source, 'dirty'), 'dirty');
    assert.notEqual(check(first).status, 0);
    fs.unlinkSync(path.join(source, 'dirty'));
    assert.equal(check('invalid').status, 2);
    result = check('b'.repeat(40));
    assert.equal(result.status, 0); assert.match(result.stdout, /MOONHUB_DEPLOY_SKIPPED:/);
    fs.writeFileSync(path.join(source, 'ahead'), 'local commit');
    git('add', '.'); git('commit', '-qm', 'unpublished');
    result = check(first);
    assert.notEqual(result.status, 0); assert.match(result.stdout, /non-fast-forward/);
    assert.equal(fs.readFileSync(calls, 'utf8'), '');
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
