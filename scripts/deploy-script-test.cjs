const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-deploy-test-'));
try {
  fs.mkdirSync(path.join(root, 'deploy'));
  fs.mkdirSync(path.join(root, 'bin'));
  fs.copyFileSync(path.join(__dirname, '../deploy/deploy.sh'), path.join(root, 'deploy/deploy.sh'));
  fs.writeFileSync(path.join(root, '.gitignore'), 'bin/\nbackups/\n*.log\ndeploy/deploy.env\nsecret\n');
  const git = args => execFileSync('git', args, { cwd: root, stdio: 'pipe' });
  git(['init', '-q']);
  git(['add', '.']);
  git(['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture']);
  fs.writeFileSync(path.join(root, 'secret'), 'a'.repeat(64), { mode: 0o600 });
  const log = path.join(root, 'commands.log');
  fs.writeFileSync(path.join(root, 'bin/docker'), `#!/bin/bash
set -eu
printf '%s\\n' "$*" >> "$TEST_LOG"
case "$*" in
  *"build "*) [ "\${TEST_FAIL:-}" != build ]; exit $? ;;
  "image inspect "*) [ "\${TEST_FAIL:-}" != image ]; exit $? ;;
  *"ps -aq web") echo web-id ;;
  *"ps -aq ssh") echo ssh-id ;;
  *"ps -q "*) echo running-id ;;
  "inspect -f {{.State.Running}} "*) echo false ;;
  "inspect -f {{.State.Status}} "*) echo running ;;
  "cp "*) [ "\${TEST_FAIL:-}" != backup ]; mkdir -p "\${3}"; printf snapshot > "\${3}/test-data" ;;
  *"exec -T --user git web sh "*) cat >/dev/null ;;
  "save "*) printf image ;;
  "exec -i "*) cat >/dev/null ;;
esac
`, { mode: 0o755 });
  const env = {
    ...process.env, PATH: path.join(root, 'bin') + ':' + process.env.PATH,
    TEST_LOG: log, MOONHUB_ROOT_PASSWORD_FILE: path.join(root, 'secret'),
    MOONHUB_PROVIDER_TOKEN_FILE: path.join(root, 'secret'),
    MOONHUB_DEPLOY_LOCK_DIR: path.join(root, 'lock'),
    MOONHUB_ENABLE_PIPELINES: '1', MOONHUB_PULL: '0',
  };
  function run(extra = {}, command = 'upgrade') {
    fs.writeFileSync(log, '');
    const result = spawnSync('bash', ['deploy/deploy.sh', command], { cwd: root, env: { ...env, ...extra }, encoding: 'utf8' });
    return { ...result, commands: fs.readFileSync(log, 'utf8').split('\n') };
  }
  let result = run({ TEST_FAIL: 'build' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line)), 'build failure stopped services');
  result = run({ MOONHUB_BUILD_IMAGES: '0', TEST_FAIL: 'image' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line)), 'missing image stopped services');
  result = run({ TEST_FAIL: 'backup' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => line.includes(' up ')), 'backup failure started replacement services');
  result = run();
  assert.equal(result.status, 0, result.stderr);
  const lines = result.commands;
  const stop = lines.findIndex(line => / stop$/.test(line));
  const builds = lines.map((line, i) => line.includes(' build ') || line.startsWith('build ') ? i : -1).filter(i => i >= 0);
  assert.equal(builds.length, 3);
  assert.ok(builds.every(i => i < stop), 'build happened during downtime');
  assert.ok(lines.findIndex(line => line.startsWith('cp web-id:/data')) > stop);
  const ensure = lines.findIndex(line => line.includes('pipeline-provider-ensure'));
  assert.ok(ensure > lines.findIndex(line => line.includes('up ') && line.includes('web ssh')));
  assert.ok(lines.findIndex(line => line.includes('--no-deps') && line.includes('pipeline-provider')) > ensure);
  assert.ok(!lines.join('\n').includes('a'.repeat(64)), 'token leaked into argv');
  assert.ok(fs.readdirSync(path.join(root, 'backups')).some(dir => fs.existsSync(path.join(root, 'backups', dir, 'data/test-data'))));
  fs.writeFileSync(path.join(root, 'deploy/deploy.env'), 'MOONHUB_ROOT_USER=custom-admin\nMOONHUB_HTTP_PORT=18999\n');
  result = run({ MOONHUB_BUILD_IMAGES: '0' });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.commands.join('\n').includes('custom-admin'));
  assert.ok(!result.commands.some(line => line.includes(' build ')));
  result = run({ MOONHUB_RUNNER_BUILD_TARGET: 'runner-selfhost', MOONBIT_VERSION: '0.10.14+7d59c7ec9' });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.commands.some(line => line.startsWith('build --target runner-selfhost --build-arg MOONBIT_VERSION=0.10.14+7d59c7ec9')));
  result = run({ MOONHUB_RUNNER_BUILD_TARGET: 'runtime' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line)));
  console.log('Deployment script tests passed: build-before-stop, image preflight, stopped backups, failure ordering, ensure and persistent settings.');
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
