const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-deploy-test-'));
try {
  fs.mkdirSync(path.join(root, 'deploy'));
  fs.mkdirSync(path.join(root, 'js'));
  fs.mkdirSync(path.join(root, 'scripts'));
  fs.copyFileSync(path.join(__dirname, 'resolve-dependencies.cjs'), path.join(root, 'scripts/resolve-dependencies.cjs'));
  fs.mkdirSync(path.join(root, 'bin'));
  fs.copyFileSync(path.join(__dirname, '../deploy/deploy.sh'), path.join(root, 'deploy/deploy.sh'));
  for (const file of ['recovery.sh', 'recovery.jq', 'base-image.sh', 'base.Dockerfile', 'configure-apt.sh', 'install-moonbit.sh', 'shared-build.sh', 'active-attempts.cjs', 'buildkitd.toml']) fs.copyFileSync(path.join(__dirname, '../deploy', file), path.join(root, 'deploy', file));
  for (const file of ['moon.mod', 'moon.pkg', '.dockerignore']) fs.copyFileSync(path.join(__dirname, '..', file), path.join(root, file));
  for (const file of ['package.json', 'package-lock.json']) fs.copyFileSync(path.join(__dirname, '../js', file), path.join(root, 'js', file));
  fs.writeFileSync(path.join(root, '.gitignore'), 'bin/\nbackups/\n*.log\ndeploy/deploy.env\nsecret\n');
  const git = args => execFileSync('git', args, { cwd: root, stdio: 'pipe' });
  git(['init', '-q']);
  git(['add', '.']);
  git(['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture']);
  fs.writeFileSync(path.join(root, 'secret'), 'a'.repeat(64), { mode: 0o600 });
  const log = path.join(root, 'commands.log');
  fs.copyFileSync(path.join(__dirname, 'fixtures/deploy-docker.cjs'), path.join(root, 'bin/docker'));
  fs.chmodSync(path.join(root, 'bin/docker'), 0o755);
  fs.copyFileSync(path.join(__dirname, 'fixtures/deploy-docker.cjs'), path.join(root, 'bin/moonhub'));
  fs.chmodSync(path.join(root, 'bin/moonhub'), 0o755);
  const env = {
    ...process.env, PATH: path.join(root, 'bin') + ':' + process.env.PATH,
    TEST_LOG: log, MOONHUB_ROOT_PASSWORD_FILE: path.join(root, 'secret'),
    MOONHUB_PROVIDER_TOKEN_FILE: path.join(root, 'secret'),
    MOONHUB_DEPLOY_LOCK_DIR: path.join(root, 'lock'),
    MOONHUB_ENABLE_PIPELINES: '1', MOONHUB_PULL: '0', MOONHUB_USE_CN_MIRRORS: '',
    MOONHUB_BASE_IMAGE: '', MOONHUB_BASE_REBUILD: '0', DOCKER_DEFAULT_PLATFORM: '',
    MOONBIT_VERSION: '', DEBIAN_MIRROR: '', DEBIAN_SECURITY_MIRROR: '',
    MOONHUB_PROVIDER_SCOPE: '', MOONHUB_PROVIDER_REPOSITORIES: '',
    MOONHUB_SHARED_HOST: '0', MOONHUB_CGROUP_PARENT: '', MOONHUB_DIND_STORAGE_DIR: '',
    MOONHUB_BACKUP_KEEP: '0',
  };
  function run(extra = {}, command = 'upgrade', answer) {
    fs.writeFileSync(log, '');
    fs.rmSync(log + '.base', { force: true });
    fs.rmSync(log + '.job-stopped', { force: true });
    const terminal = answer !== undefined;
    const executable = terminal ? 'python3' : 'bash';
    const args = terminal ? [path.join(__dirname, 'fixtures/pty-run.py'), answer, 'bash', 'deploy/deploy.sh', command] : ['deploy/deploy.sh', ...[command].flat()];
    const result = spawnSync(executable, args, { cwd: root, env: { ...env, ...extra }, encoding: 'utf8', input: answer, timeout: 30000 });
    return { ...result, commands: fs.readFileSync(log, 'utf8').split('\n') };
  }
  function ensureArgs(result) {
    const line = result.commands.find(line => line.startsWith('provider-ensure-argv '));
    assert.ok(line, 'provider ensure was not invoked');
    return JSON.parse(line.slice('provider-ensure-argv '.length));
  }
  let result = run({ TEST_FAIL: 'build' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line)), 'build failure stopped services');
  result = run({ MOONHUB_SHARED_HOST: '1' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => line.includes(' build ')), 'shared-host profile permitted unrestricted builds');
  result = run({ MOONHUB_SHARED_HOST: '1', MOONHUB_BUILD_IMAGES: '0', MOONHUB_CGROUP_PARENT: 'moonhub.slice', MOONHUB_DIND_STORAGE_DIR: root });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.commands.some(line => line.includes('compose.shared-host.yaml')));
  result = run({ MOONHUB_SHARED_HOST: '1', MOONHUB_BUILD_IMAGES: '0', MOONHUB_CGROUP_PARENT: 'moonhub.slice', MOONHUB_DIND_STORAGE_DIR: root }, 'build-base');
  assert.notEqual(result.status, 0);
  assert.equal(result.commands.length, 1, 'shared-host build-base bypassed build isolation');
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
  assert.ok(runnerBuild.includes('--build-arg MOONHUB_BASE_IMAGE=moonhub-base:'));
  const baseImage = runnerBuild.match(/MOONHUB_BASE_IMAGE=(\S+)/)[1];
  assert.deepEqual(lines.filter(line => line.startsWith('compose-base ')), [`compose-base ${baseImage}`, `compose-base ${baseImage}`]);
  assert.ok(builds.every(i => i < stop), 'build happened during downtime');
  assert.ok(lines.findIndex(line => line.startsWith('cp web-id:/data')) > stop);
  assert.ok(lines.findIndex(line => line.startsWith('save ')) < stop || result.stdout.includes('Reusing compressed image archive: images-'), 'image export happened during downtime');
  assert.ok(lines.some(line => line.startsWith('info --format')));
  assert.ok(!lines.some(line => line.includes('base.Dockerfile')), 'existing dependency base was rebuilt');
  const ensure = lines.findIndex(line => line.includes('pipeline-provider-ensure'));
  assert.ok(ensure > lines.findIndex(line => line.includes('up ') && line.includes('web ssh')));
  assert.ok(lines.findIndex(line => line.includes('--no-deps') && line.includes('pipeline-provider')) > ensure);
  assert.ok(!lines.join('\n').includes('a'.repeat(64)), 'token leaked into argv');
  assert.ok(ensureArgs(result).includes('--preserve-existing'));
  assert.ok(!ensureArgs(result).includes('--scope'), 'default upgrade overwrote saved provider scope');
  const backup = fs.readdirSync(path.join(root, 'backups')).find(dir => !dir.startsWith('.'));
  const bundle = path.join(root, 'backups', backup);
  assert.ok(fs.existsSync(path.join(bundle, 'data.tar')));
  const recovered = JSON.parse(fs.readFileSync(path.join(bundle, 'compose.json')));
  assert.equal(recovered.services.web.image, 'sha256:' + '1'.repeat(64));
  assert.ok(!recovered.services.web.image.includes('new-tag'));
  assert.ok(recovered.services.web.environment.includes('LITERAL=$$not_an_env'));
  assert.ok(recovered.services['pipeline-provider'].environment.some(value => /^MOONHUB_RUNNER_IMAGE=sha256:[a-f0-9]{64}$/.test(value)));
  execFileSync('shasum', ['-a', '256', '-c', 'SHA256SUMS'], { cwd: bundle, stdio: 'pipe' });
  // Exercise recovery of older backups that did not record a scope setting.
  const manifestPath = path.join(bundle, 'manifest.json');
  const legacyManifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  assert.equal(legacyManifest.provider_scope, '');
  delete legacyManifest.provider_scope;
  fs.writeFileSync(manifestPath, JSON.stringify(legacyManifest));
  const manifestHash = createHash('sha256').update(fs.readFileSync(manifestPath)).digest('hex');
  const checksumPath = path.join(bundle, 'SHA256SUMS');
  fs.writeFileSync(checksumPath, fs.readFileSync(checksumPath, 'utf8').split('\n').map(line =>
    line.endsWith('  ./manifest.json') ? `${manifestHash}  ./manifest.json` : line).join('\n'));
  result = run({ MOONHUB_PROVIDER_SCOPE: 'selected', MOONHUB_PROVIDER_REPOSITORIES: 'alice/demo,bob/service' });
  assert.equal(result.status, 0, result.stderr);
  const selectedArgs = ensureArgs(result);
  assert.ok(selectedArgs.includes('--preserve-existing'));
  assert.equal(selectedArgs[selectedArgs.indexOf('--scope') + 1], 'selected');
  assert.equal(selectedArgs[selectedArgs.indexOf('--repositories') + 1], 'alice/demo,bob/service');
  const sharedRoot = path.join(root, 'backups/shared');
  result = run({ MOONHUB_PROVIDER_SCOPE: 'all', MOONHUB_BACKUP_DIR: sharedRoot });
  assert.equal(result.status, 0, result.stderr);
  const sharedArgs = ensureArgs(result);
  assert.equal(sharedArgs[sharedArgs.indexOf('--scope') + 1], 'all');
  assert.equal(sharedArgs[sharedArgs.indexOf('--repositories') + 1], '');
  const sharedBundle = path.join(sharedRoot, fs.readdirSync(sharedRoot).find(name => !name.startsWith('.')));
  assert.equal(JSON.parse(fs.readFileSync(path.join(sharedBundle, 'manifest.json'))).provider_scope, 'all');
  result = run({ TEST_FRESH: '1' }, ['restore', sharedBundle, '--project', 'shared', '--http-port', '19005', '--ssh-port', '19006', '--pipeline-prefix', '172.30.97']);
  assert.equal(result.status, 0, result.stderr);
  const sharedStates = path.join(sharedRoot, 'recovered');
  const sharedState = fs.readdirSync(sharedStates).find(entry => fs.existsSync(path.join(sharedStates, entry, 'upgrade.env')));
  assert.ok(fs.readFileSync(path.join(sharedStates, sharedState, 'upgrade.env'), 'utf8').includes("MOONHUB_PROVIDER_SCOPE='all'"));
  for (const invalid of [
    { MOONHUB_PROVIDER_SCOPE: 'invalid' },
    { MOONHUB_PROVIDER_SCOPE: 'all', MOONHUB_PROVIDER_REPOSITORIES: 'alice/demo' },
  ]) {
    result = run(invalid);
    assert.notEqual(result.status, 0);
    assert.equal(result.commands.length, 1, 'invalid provider scope reached Docker');
  }
  result = run({ TEST_FAIL: 'active-job' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line)), 'active jobs stopped services');
  assert.ok(!result.commands.some(line => line.startsWith('stop ')), 'unconfirmed interruption stopped a provider');
  assert.ok(result.commands.some(line => line.startsWith('unpause ')), 'declined noninteractive upgrade left claims frozen');
  result = run({ TEST_ACTIVE: '1' }, 'upgrade', 'n\n');
  assert.notEqual(result.status, 0);
  assert.match(result.stdout, /Continue upgrade\? \[y\/N\]/, result.stderr + (result.error?.message || ''));
  assert.ok(!result.commands.some(line => line.startsWith('stop ') || / stop$/.test(line)), 'negative answer interrupted work');
  assert.ok(result.commands.some(line => line.startsWith('unpause ')));
  result = run({ TEST_ACTIVE: '1' }, 'upgrade', 'yes\n');
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.ok(result.commands.some(line => line.includes('docker.sock stop -t 15')));
  result = run({ TEST_LEASED: '1' });
  assert.notEqual(result.status, 0, 'leased attempt without a container bypassed confirmation');
  assert.ok(!result.commands.some(line => line.startsWith('stop ')));
  result = run({ TEST_ACTIVE: '1' }, ['upgrade', '--interrupt-jobs']);
  assert.equal(result.status, 0, result.stderr);
  const interrupt = result.commands.findIndex(line => line.includes('docker.sock stop -t 15'));
  assert.ok(interrupt > result.commands.findIndex(line => line.startsWith('build ')), 'job was interrupted before builds finished');
  assert.ok(interrupt < result.commands.findIndex(line => line.startsWith('cp web-id:/data')), 'job was not interrupted before data backup');
  result = run({ TEST_FAIL: 'backup' });
  assert.notEqual(result.status, 0);
  assert.ok(result.commands.some(line => line === 'start pipeline-provider-id'), 'backup failure did not restore original provider');
  result = run({ TEST_BAD_MOUNT: '1' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line)), 'unsupported mount stopped services');
  fs.writeFileSync(path.join(root, 'deploy/deploy.env'), 'MOONHUB_ROOT_USER=custom-admin\nMOONHUB_HTTP_PORT=18999\nMOONHUB_PROVIDER_SCOPE=all\n');
  result = run({ MOONHUB_BUILD_IMAGES: '0' });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.commands.join('\n').includes('custom-admin'));
  const configuredArgs = ensureArgs(result);
  assert.equal(configuredArgs[configuredArgs.indexOf('--scope') + 1], 'all');
  assert.ok(!result.commands.some(line => line.includes(' build ')));
  result = run({ MOONHUB_RUNNER_BUILD_TARGET: 'runner-selfhost', MOONBIT_VERSION: '0.10.14+7d59c7ec9' });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.commands.some(line => line.startsWith('build --target runner-selfhost --platform linux/amd64 --build-arg MOONHUB_BASE_IMAGE=moonhub-base:')));
  fs.appendFileSync(path.join(root, 'deploy/deploy.env'), 'DEBIAN_MIRROR=http://deb.debian.org/debian\nDEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security\n');
  for (const pull of ['0', '1']) {
    for (const mirrors of ['0', '1']) {
      result = run({ TEST_BASE_MISSING: '1', MOONHUB_PULL: pull, MOONHUB_USE_CN_MIRRORS: mirrors }, 'build');
      assert.equal(result.status, 0, result.stderr);
      const base = result.commands.find(line => line.startsWith('build ') && line.includes('base.Dockerfile'));
      assert.ok(base.includes(`--build-arg MOONHUB_USE_CN_MIRRORS=${mirrors} `));
      assert.ok(base.includes('--build-arg DEBIAN_MIRROR=http://deb.debian.org/debian '));
      assert.ok(base.includes('--build-arg DEBIAN_SECURITY_MIRROR=http://deb.debian.org/debian-security '));
      assert.equal(base.includes('--pull'), pull === '1');
      assert.ok(!result.commands.some(line => /build.*--pull/.test(line) && !line.includes('base.Dockerfile')), 'application build tried pulling the local base');
    }
  }
  result = run({ MOONHUB_USE_CN_MIRRORS: 'true' });
  assert.notEqual(result.status, 0);
  assert.equal(result.commands.length, 1, 'invalid source switch reached Docker');
  fs.appendFileSync(path.join(root, 'deploy/deploy.env'), 'MOONHUB_USE_CN_MIRRORS=1\n');
  result = run({ TEST_BASE_MISSING: '1' }, 'build');
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.commands.some(line => line.startsWith('build ') && line.includes('--build-arg MOONHUB_USE_CN_MIRRORS=1 ')));
  result = run({ MOONHUB_RUNNER_BUILD_TARGET: 'runtime' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line)));
  result = run({ TEST_BASE_MISSING: '1' }, 'build');
  assert.equal(result.status, 0, result.stderr);
  const baseBuild = result.commands.find(line => line.includes('base.Dockerfile'));
  assert.ok(baseBuild);
  assert.ok(baseBuild.includes('--build-arg MOONHUB_USE_CN_MIRRORS=1'));
  assert.ok(baseBuild.includes('--build-arg DEBIAN_MIRROR=http://deb.debian.org/debian'));
  assert.equal(result.commands.filter(line => line.includes('base.Dockerfile')).length, 1);
  result = run({ TEST_BASE_MISSING: '1', TEST_FAIL: 'base-build' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line) || line.startsWith('stop ')), 'base failure stopped services');
  assert.ok(!result.commands.some(line => line.startsWith('compose-base ')), 'base failure built application');
  result = run({ MOONHUB_BASE_REBUILD: '1' }, 'build');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.commands.filter(line => line.includes('base.Dockerfile')).length, 1);
  assert.ok(result.commands.find(line => line.includes('base.Dockerfile')).includes('--no-cache'));
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
  assert.ok(!fs.readFileSync(path.join(state, 'upgrade.env'), 'utf8').includes('MOONHUB_PROVIDER_SCOPE='), 'recovery introduced an explicit scope');
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
  const basic = path.join(basicRoot, fs.readdirSync(basicRoot).find(name => !name.startsWith('.')));
  result = run({ TEST_FRESH: '1' }, ['restore', basic, '--project', 'basic', '--http-port', '19003', '--ssh-port', '19004']);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!result.commands.join('\n').includes('pipeline-docker'), 'basic restore started DinD');
  const limitedRoot = path.join(root, 'backups/limited');
  result = run({ TEST_RESOURCE_LIMITS: '1', MOONHUB_BACKUP_DIR: limitedRoot });
  assert.equal(result.status, 0, result.stderr);
  const limitedBundle = path.join(limitedRoot, fs.readdirSync(limitedRoot).find(name => !name.startsWith('.')));
  const limited = JSON.parse(fs.readFileSync(path.join(limitedBundle, 'compose.json')));
  assert.equal(limited.services.web.cgroup_parent, 'moonhub.slice');
  assert.equal(limited.services.web.cpus, 0.5);
  assert.equal(limited.services.web.mem_limit, 536870912);
  assert.equal(limited.services.web.logging.options['max-size'], '10m');
  result = run({ TEST_FRESH: '1' }, ['restore', limitedBundle]);
  assert.notEqual(result.status, 0, 'generic restore silently discarded bounded storage');
  assert.equal(result.commands.length, 1, 'limited restore reached Docker without a provisioned resource profile');
  // Real gzip/tar/checksum/hard-link operations, with only Docker responses mocked.
  const efficientRoot = path.join(root, 'backups/efficient');
  const efficientEnv = { MOONHUB_BACKUP_DIR: efficientRoot };
  result = run(efficientEnv);
  assert.equal(result.status, 0, result.stderr);
  const completeBundles = () => fs.readdirSync(efficientRoot).filter(name => /^20\d{6}-\d{6}\./.test(name));
  const firstEfficient = path.join(efficientRoot, completeBundles()[0]);
  const firstArchive = fs.statSync(path.join(firstEfficient, 'images.tar'));
  for (const file of ['images.tar', 'runner.tar']) {
    assert.deepEqual([...fs.readFileSync(path.join(firstEfficient, file)).subarray(0, 2)], [0x1f, 0x8b]);
    execFileSync('gzip', ['-t', path.join(firstEfficient, file)]);
  }
  result = run(efficientEnv);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!result.commands.some(line => line.startsWith('save moonhub-recovery:') || line.includes('docker.sock save ')), 'unchanged backup images were exported twice');
  const secondEfficient = path.join(efficientRoot, completeBundles().find(name => path.join(efficientRoot, name) !== firstEfficient));
  assert.equal(fs.statSync(path.join(secondEfficient, 'images.tar')).ino, firstArchive.ino, 'archives duplicated disk blocks');
  // A copied bundle is sufficient; the source cache and source bundle are optional.
  const standalone = path.join(root, 'backups/standalone');
  fs.cpSync(secondEfficient, standalone, { recursive: true });
  result = run({ TEST_FRESH: '1' }, ['restore', standalone, '--project', 'standalone', '--http-port', '19007', '--ssh-port', '19008', '--pipeline-prefix', '172.30.96']);
  assert.equal(result.status, 0, result.stderr);
  // Existing uncompressed bundles remain valid with the updated recovery tool.
  for (const file of ['images.tar', 'runner.tar']) {
    const archive = path.join(standalone, file);
    fs.writeFileSync(archive, require('node:zlib').gunzipSync(fs.readFileSync(archive)));
    const hash = createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
    const sums = path.join(standalone, 'SHA256SUMS');
    fs.writeFileSync(sums, fs.readFileSync(sums, 'utf8').split('\n').map(line => line.endsWith(`  ./${file}`) ? `${hash}  ./${file}` : line).join('\n'));
  }
  result = run({ TEST_FRESH: '1' }, ['restore', standalone, '--project', 'legacy', '--http-port', '19007', '--ssh-port', '19008', '--pipeline-prefix', '172.30.96']);
  assert.equal(result.status, 0, result.stderr);
  const orphanArchive = path.join(efficientRoot, '.image-cache/unreferenced.tar.gz');
  fs.writeFileSync(orphanArchive, require('node:zlib').gzipSync('unused'));
  fs.writeFileSync(orphanArchive + '.sha256', 'unused');
  // Retention runs only after success and leaves unrelated/incomplete directories alone.
  const oldBundle = path.join(efficientRoot, '20200101-000000.old');
  fs.renameSync(firstEfficient, oldBundle);
  const unrelated = path.join(efficientRoot, '20190101-000000.other');
  fs.cpSync(oldBundle, unrelated, { recursive: true });
  const otherManifest = JSON.parse(fs.readFileSync(path.join(unrelated, 'manifest.json')));
  otherManifest.project = 'other-project';
  fs.writeFileSync(path.join(unrelated, 'manifest.json'), JSON.stringify(otherManifest));
  result = run({ ...efficientEnv, MOONHUB_BACKUP_KEEP: '2', TEST_FAIL: 'start' });
  assert.notEqual(result.status, 0);
  assert.ok(fs.existsSync(oldBundle), 'failed switch pruned recovery history');
  result = run({ ...efficientEnv, MOONHUB_BACKUP_KEEP: '2' });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!fs.existsSync(oldBundle));
  assert.ok(fs.existsSync(unrelated));
  assert.ok(!fs.existsSync(orphanArchive), 'unreferenced cached image was retained');
  assert.equal(completeBundles().filter(name => name !== path.basename(unrelated)).length, 2);
  // Export/data-copy failures never leave partial bundles behind.
  result = run({ ...efficientEnv, TEST_FAIL: 'backup' });
  assert.notEqual(result.status, 0);
  assert.ok(!fs.readdirSync(efficientRoot).some(name => name.startsWith('.partial-')));
  const cachedImage = path.join(efficientRoot, '.image-cache', fs.readdirSync(path.join(efficientRoot, '.image-cache')).find(name => /^images-.*\.tar\.gz$/.test(name)));
  fs.unlinkSync(cachedImage); // do not mutate the retained bundles' linked bytes
  fs.writeFileSync(cachedImage, 'corrupt cached image');
  result = run(efficientEnv);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.commands.some(line => line.startsWith('save moonhub-recovery:')), 'corrupt image cache was reused');
  const failedRoot = path.join(root, 'backups/failed-export');
  result = run({ MOONHUB_BACKUP_DIR: failedRoot, TEST_FAIL: 'export' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(line => / stop$/.test(line)), 'export failure stopped Web/SSH');
  assert.ok(!fs.readdirSync(failedRoot).some(name => name.startsWith('.partial-')));
  assert.ok(!fs.readdirSync(path.join(failedRoot, '.image-cache')).some(name => name.startsWith('.pending-')));
  for (const invalid of ['-1', '1001', 'all']) {
    result = run({ MOONHUB_BACKUP_KEEP: invalid });
    assert.notEqual(result.status, 0);
    assert.equal(result.commands.length, 1, 'invalid retention reached Docker');
  }
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
  console.log('Deployment script tests passed: compressed/legacy standalone restore, checksum-verified image reuse and hard links, safe retention/cache GC, failed export cleanup, provider scopes, build-before-stop, corruption rejection and protected replacement.');
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
