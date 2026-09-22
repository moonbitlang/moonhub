const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-bounded-build-'));
try {
  fs.mkdirSync(path.join(root, 'deploy'));
  fs.mkdirSync(path.join(root, 'bin'));
  for (const file of ['shared-build.sh', 'buildkitd.toml']) fs.copyFileSync(path.join(__dirname, '../deploy', file), path.join(root, 'deploy', file));
  fs.writeFileSync(path.join(root, '.gitignore'), 'bin/\n*.log\nbake.json\n');
  const git = args => execFileSync('git', args, { cwd: root, stdio: 'pipe' });
  git(['init', '-q']); git(['add', '.']);
  git(['-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'test']);
  const revision = git(['rev-parse', 'HEAD']).toString().trim();
  fs.writeFileSync(path.join(root, 'bin/cat'), '#!/bin/sh\ncase "$1" in */memory.max) echo 10737418240;; */cpu.max) echo "400000 100000";; *) exec /bin/cat "$@";; esac\n', { mode: 0o755 });
  fs.writeFileSync(path.join(root, 'bin/df'), '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 99999999 1 50000000 1%% /\\n"\n', { mode: 0o755 });
  fs.writeFileSync(path.join(root, 'bin/docker'), `#!/usr/bin/env node
const fs = require('node:fs'), a = process.argv.slice(2);
fs.appendFileSync(process.env.TEST_LOG, JSON.stringify(a) + '\\n');
if (a[0] === 'info') console.log(a.includes('{{.CgroupDriver}}/{{.CgroupVersion}}') ? 'systemd/2' : 'linux/x86_64');
else if (a[0] === 'container' && a[1] === 'inspect') process.exit(1);
else if (a[0] === 'buildx' && a[1] === 'bake') {
 const file=a[a.indexOf('--file')+1]; fs.copyFileSync(file, process.env.TEST_BAKE);
 if(process.env.TEST_FAIL==='1') process.exit(1);
} else if (a[0] === 'image' && a.includes('-f')) console.log(process.env.TEST_REVISION);
`, { mode: 0o755 });
  const log = path.join(root, 'commands.log');
  const bake = path.join(root, 'bake.json');
  const env = { ...process.env, PATH: path.join(root, 'bin') + ':' + process.env.PATH,
    ROOT: root, PROJECT: 'moonhub-test', MOONHUB_CGROUP_PARENT: 'moonhub.slice',
    CONFIGURED_IMAGES: '', BUILD_RUNNER: '1', USE_CN_MIRRORS: '0', PULL_IMAGES: '0', REBUILD_BASE: '0',
    RUNNER_BUILD_TARGET: 'runner', RUNTIME_IMAGE: 'moonhub:' + revision.slice(0,12),
    PROVIDER_IMAGE: 'moonhub-provider:' + revision.slice(0,12), RUNNER_IMAGE: 'moonhub-runner:' + revision.slice(0,12),
    RECOVERY_TOOL_REVISION: revision, TEST_REVISION: revision, TEST_LOG: log, TEST_BAKE: bake,
    MOONHUB_BASE_IMAGE: '', MOONHUB_RELEASE_TAG: '',
  };
  function run(extra = {}) {
    fs.writeFileSync(log, '');
    const result = spawnSync('bash', ['-c', 'set -Eeuo pipefail; BUILD_STAGE=""; trap \'[ -z "$BUILD_STAGE" ] || rm -rf "$BUILD_STAGE"\' EXIT; . deploy/shared-build.sh; build_shared_images'], { cwd: root, env: { ...env, ...extra }, encoding: 'utf8' });
    return { ...result, commands: fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) };
  }
  let result = run();
  assert.equal(result.status, 0, result.stderr);
  const container = result.commands.find(a => a[0] === 'run');
  for (const [flag, value] of [['--cpus','2'], ['--memory','4g'], ['--memory-swap','4g'], ['--cgroup-parent','moonhub.slice'], ['--pids-limit','512']]) assert.equal(container[container.indexOf(flag)+1], value);
  assert.ok(!container.some(arg => arg.includes('docker.sock') || arg.includes('provider_token')));
  const plan = JSON.parse(fs.readFileSync(bake));
  assert.deepEqual(plan.group.default.targets, ['web', 'provider', 'runner']);
  for (const name of ['web', 'provider', 'runner']) {
    assert.deepEqual(plan.target[name].contexts, { 'moonhub-base:local': 'target:dependency-base' });
    assert.deepEqual(plan.target[name].output, ['type=docker']);
    assert.equal(plan.target[name].labels['org.opencontainers.image.revision'], revision);
  }
  assert.equal(plan.target['dependency-base'].args.MOONHUB_USE_CN_MIRRORS, '0');
  assert.ok(result.commands.some(a => a[0] === 'stop' && a[1] === 'moonhub-test-buildkit'));
  result = run({ CONFIGURED_IMAGES: 'moonhub:old' });
  assert.notEqual(result.status, 0);
  assert.equal(result.commands.length, 0);
  result = run({ TEST_FAIL: '1' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(a => a[0] === 'image'), 'failed build was accepted as a new release');
  console.log('Bounded build tests passed: 2 CPU/4 GiB isolation, committed context, linked base target, commit labels and failure rejection.');
} finally { fs.rmSync(root, { recursive: true, force: true }); }
