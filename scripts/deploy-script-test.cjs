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
  for (const file of ['recovery.sh', 'recovery.jq']) fs.copyFileSync(path.join(__dirname, '../deploy', file), path.join(root, 'deploy', file));
  fs.writeFileSync(path.join(root, '.gitignore'), 'bin/\nbackups/\n*.log\ndeploy/deploy.env\nsecret\n');
  const git = args => execFileSync('git', args, { cwd: root, stdio: 'pipe' });
  git(['init', '-q']);
  git(['add', '.']);
  git(['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture']);
  fs.writeFileSync(path.join(root, 'secret'), 'a'.repeat(64), { mode: 0o600 });
  const log = path.join(root, 'commands.log');
  fs.copyFileSync(path.join(__dirname, 'fixtures/deploy-docker.cjs'), path.join(root, 'bin/docker'));
  fs.chmodSync(path.join(root, 'bin/docker'), 0o755);
  const env = {
    ...process.env, PATH: path.join(root, 'bin') + ':' + process.env.PATH,
    TEST_LOG: log, MOONHUB_ROOT_PASSWORD_FILE: path.join(root, 'secret'),
    MOONHUB_PROVIDER_TOKEN_FILE: path.join(root, 'secret'),
    MOONHUB_DEPLOY_LOCK_DIR: path.join(root, 'lock'),
    MOONHUB_ENABLE_PIPELINES: '1', MOONHUB_PULL: '0', MOONHUB_USE_CN_MIRRORS: '',
  };
  function run(extra = {}, command = 'upgrade') {
    fs.writeFileSync(log, '');
    const result = spawnSync('bash', ['deploy/deploy.sh', ...[command].flat()], { cwd: root, env: { ...env, ...extra }, encoding: 'utf8' });
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
  const runnerBuild = lines.find(line => line.startsWith('build '));
  assert.ok(runnerBuild.includes('--build-arg MOONHUB_USE_CN_MIRRORS=0 '));
  assert.ok(runnerBuild.includes('--build-arg DEBIAN_MIRROR=http://mirrors.ustc.edu.cn/debian '));
  assert.ok(runnerBuild.includes('--build-arg DEBIAN_SECURITY_MIRROR=http://mirrors.ustc.edu.cn/debian-security '));
  assert.ok(builds.every(i => i < stop), 'build happened during downtime');
  assert.ok(lines.findIndex(line => line.startsWith('cp web-id:/data')) > stop);
  assert.ok(lines.findIndex(line => line.startsWith('save ')) < stop, 'image export happened during downtime');
  const ensure = lines.findIndex(line => line.includes('pipeline-provider-ensure'));
  assert.ok(ensure > lines.findIndex(line => line.includes('up ') && line.includes('web ssh')));
  assert.ok(lines.findIndex(line => line.includes('--no-deps') && line.includes('pipeline-provider')) > ensure);
  assert.ok(!lines.join('\n').includes('a'.repeat(64)), 'token leaked into argv');
  const backup = fs.readdirSync(path.join(root, 'backups')).find(dir => !dir.startsWith('.partial-'));
  const bundle = path.join(root, 'backups', backup);
  assert.ok(fs.existsSync(path.join(bundle, 'data.tar')));
  const recovered = JSON.parse(fs.readFileSync(path.join(bundle, 'compose.json')));
  assert.equal(recovered.services.web.image, 'sha256:' + '1'.repeat(64));
  assert.ok(!recovered.services.web.image.includes('new-tag'));
  assert.ok(recovered.services.web.environment.includes('LITERAL=$$not_an_env'));
  assert.ok(recovered.services['pipeline-provider'].environment.some(value => /^MOONHUB_RUNNER_IMAGE=sha256:[a-f0-9]{64}$/.test(value)));
  execFileSync('shasum', ['-a', '256', '-c', 'SHA256SUMS'], { cwd: bundle, stdio: 'pipe' });
  result = run({ TEST_FAIL: 'active-job' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line)), 'active jobs stopped services');
  result = run({ TEST_BAD_MOUNT: '1' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line)), 'unsupported mount stopped services');
  fs.writeFileSync(path.join(root, 'deploy/deploy.env'), 'MOONHUB_ROOT_USER=custom-admin\nMOONHUB_HTTP_PORT=18999\n');
  result = run({ MOONHUB_BUILD_IMAGES: '0' });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.commands.join('\n').includes('custom-admin'));
  assert.ok(!result.commands.some(line => line.includes(' build ')));
  result = run({ MOONHUB_RUNNER_BUILD_TARGET: 'runner-selfhost', MOONBIT_VERSION: '0.10.14+7d59c7ec9' });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.commands.some(line => line.startsWith('build --target runner-selfhost --build-arg MOONBIT_VERSION=0.10.14+7d59c7ec9')));
  fs.appendFileSync(path.join(root, 'deploy/deploy.env'), 'DEBIAN_MIRROR=http://deb.debian.org/debian\nDEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security\n');
  for (const pull of ['0', '1']) {
    for (const mirrors of ['0', '1']) {
      result = run({ MOONHUB_PULL: pull, MOONHUB_USE_CN_MIRRORS: mirrors }, 'build');
      assert.equal(result.status, 0, result.stderr);
      const runner = result.commands.find(line => line.startsWith('build '));
      assert.ok(runner.includes(`--build-arg MOONHUB_USE_CN_MIRRORS=${mirrors} `));
      assert.ok(runner.includes('--build-arg DEBIAN_MIRROR=http://deb.debian.org/debian '));
      assert.ok(runner.includes('--build-arg DEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security '));
    }
  }
  result = run({ MOONHUB_USE_CN_MIRRORS: 'true' });
  assert.notEqual(result.status, 0);
  assert.equal(result.commands.length, 1, 'invalid source switch reached Docker');
  fs.appendFileSync(path.join(root, 'deploy/deploy.env'), 'MOONHUB_USE_CN_MIRRORS=1\n');
  result = run({}, 'build');
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.commands.some(line => line.startsWith('build ') && line.includes('--build-arg MOONHUB_USE_CN_MIRRORS=1 ')));
  result = run({ MOONHUB_RUNNER_BUILD_TARGET: 'runtime' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line)));
  result = run({}, ['restore', bundle]);
  assert.notEqual(result.status, 0, 'restore replaced an existing deployment without confirmation');
  assert.ok(!result.commands.some(line => line.startsWith('stop ') || line.includes(' up ')));
  result = run({ TEST_FRESH: '1', TEST_STORAGE_CHANGE: '1' }, ['restore', bundle, '--project', 'recovered', '--http-port', '19001', '--ssh-port', '19002', '--pipeline-prefix', '172.30.98']);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!result.commands.some(line => line.includes(' build ') || line.includes(' pull ') || line.includes('pipeline-provider-ensure')));
  const freshUp = result.commands.findIndex(line => line.includes(' up '));
  assert.equal(result.commands.filter(line => line.startsWith('run ')).length, 2);
  assert.ok(result.commands.findIndex(line => line.startsWith('run ')) < freshUp);
  const states = path.join(root, 'backups/recovered');
  const state = path.join(states, fs.readdirSync(states)[0]);
  const restored = JSON.parse(fs.readFileSync(path.join(state, 'compose.json')));
  assert.equal(restored.services.web.image, 'sha256:' + '9'.repeat(64), 'cross-storage restore did not pin the loaded local image ID');
  assert.equal(restored.services.web.ports[0].published, '19001');
  assert.equal(restored.services.web.ports[0].host_ip, '127.0.0.1');
  assert.equal(restored.services.web.networks.pipeline.ipv4_address, '172.30.98.10');
  assert.ok(restored.volumes.data.name.startsWith('recovered-'));
  assert.ok(fs.readFileSync(path.join(state, 'upgrade.env'), 'utf8').includes('MOONHUB_DATA_VOLUME='));
  result = run({ TEST_FAIL: 'extract' }, ['restore', bundle, '--replace']);
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => line.startsWith('stop ') || line.includes(' up ')), 'failed extraction touched current services');
  result = run({}, ['restore', bundle, '--replace']);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.commands.findIndex(line => line.startsWith('cp web-id:/data')) < result.commands.findIndex(line => line.includes(' up ')));
  assert.ok(!result.commands.some(line => line.startsWith('volume rm')), 'restore deleted original volumes');
  result = run({ TEST_FAIL: 'backup' }, ['restore', bundle, '--replace']);
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => line.includes(' up ')), 'failed protection backup started replacement');
  result = run({ TEST_FAIL: 'start' }, ['restore', bundle, '--replace']);
  assert.notEqual(result.status, 0);
  assert.ok(result.commands.findIndex(line => line.startsWith('cp web-id:/data')) < result.commands.findIndex(line => line.includes(' up ')));
  assert.ok(!result.commands.some(line => line.startsWith('volume rm')), 'startup failure deleted original volumes');
  const basicRoot = path.join(root, 'backups/basic');
  result = run({ TEST_BASIC: '1', MOONHUB_ENABLE_PIPELINES: '0', MOONHUB_BACKUP_DIR: basicRoot });
  assert.equal(result.status, 0, result.stderr);
  const basic = path.join(basicRoot, fs.readdirSync(basicRoot)[0]);
  result = run({ TEST_FRESH: '1' }, ['restore', basic, '--project', 'basic', '--http-port', '19003', '--ssh-port', '19004']);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!result.commands.join('\n').includes('pipeline-docker'), 'basic restore started DinD');
  const checksums = fs.readFileSync(path.join(bundle, 'SHA256SUMS'), 'utf8');
  fs.writeFileSync(path.join(bundle, 'SHA256SUMS'), checksums.split('\n').filter(line => !line.endsWith('./data.tar')).join('\n'));
  result = run({ TEST_FRESH: '1' }, ['restore', bundle]);
  assert.notEqual(result.status, 0);
  assert.equal(result.commands.length, 1, 'incomplete checksum inventory reached Docker');
  fs.writeFileSync(path.join(bundle, 'SHA256SUMS'), checksums);
  fs.appendFileSync(path.join(bundle, 'data.tar'), 'corrupt');
  result = run({ TEST_FRESH: '1' }, ['restore', bundle]);
  assert.notEqual(result.status, 0);
  assert.equal(result.commands.length, 1, 'corrupt backup reached Docker');
  console.log('Deployment script tests passed: build-before-stop, image preflight, recovery bundles, basic/pipeline restores, corruption rejection, failure ordering and protected replacement.');
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
