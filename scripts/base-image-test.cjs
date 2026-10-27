const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-base-test-'));
try {
  const inputs = ['deploy/base.Dockerfile', 'deploy/configure-apt.sh', 'deploy/install-moonbit.sh',
    '.dockerignore', 'moon.mod', 'moon.work', 'js/package.json', 'js/package-lock.json', 'scripts/resolve-dependencies.cjs'];
  for (const file of [...inputs, 'deploy/base-image.sh']) {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.copyFileSync(path.join(__dirname, '..', file), path.join(root, file));
  }
  fs.mkdirSync(path.join(root, 'bin'));
  const log = path.join(root, 'commands.jsonl');
  const store = path.join(root, 'images.json');
  fs.writeFileSync(store, '{}');
  fs.writeFileSync(path.join(root, 'bin/docker'), `#!/usr/bin/env node
const fs = require('node:fs');
const a = process.argv.slice(2), images = JSON.parse(fs.readFileSync(process.env.TEST_STORE));
fs.appendFileSync(process.env.TEST_LOG, JSON.stringify(a) + '\\n');
if (a[0] === 'info') console.log('linux/aarch64');
else if (a[0] === 'image') process.exit(images[a.at(-1)] ? 0 : 1);
else if (a[0] === 'build') {
  if (process.env.TEST_FAIL === '1') process.exit(1);
  images[a[a.indexOf('-t') + 1]] = true;
  fs.writeFileSync(process.env.TEST_STORE, JSON.stringify(images));
} else if (a[0] === 'tag') {
  if (!images[a[1]]) process.exit(1);
  images[a[2]] = true;
  fs.writeFileSync(process.env.TEST_STORE, JSON.stringify(images));
} else process.exit(2);
`, { mode: 0o755 });
  const run = (extra = {}) => {
    fs.writeFileSync(log, '');
    const result = spawnSync('bash', ['-c', 'set -Eeuo pipefail; . deploy/base-image.sh; ensure_base_image; printf "RESULT=%s\\n" "$MOONHUB_BASE_IMAGE"'], {
      cwd: root, encoding: 'utf8', timeout: 10000,
      env: { ...process.env, ROOT: root, PATH: path.join(root, 'bin') + ':' + process.env.PATH,
        TEST_STORE: store, TEST_LOG: log, USE_CN_MIRRORS: '0', REBUILD_BASE: '0', PULL_IMAGES: '1',
        DOCKER_DEFAULT_PLATFORM: '', MOONHUB_BASE_IMAGE: '', MOONBIT_VERSION: '', DEBIAN_MIRROR: '',
        DEBIAN_SECURITY_MIRROR: '', TEST_FAIL: '', ...extra },
    });
    return { ...result, image: result.stdout.match(/^RESULT=(.+)$/m)?.[1],
      commands: fs.readFileSync(log, 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line)) };
  };
  const built = result => result.commands.filter(a => a[0] === 'build');
  let result = run();
  assert.equal(result.status, 0, result.stderr);
  const original = result.image;
  assert.match(original, /^moonhub-base:[a-f0-9]{64}$/);
  assert.equal(built(result).length, 1);
  assert.ok(built(result)[0].includes('--pull'));
  assert.ok(built(result)[0].includes('linux/arm64'));
  result = run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.image, original);
  assert.equal(built(result).length, 0, 'cached base rebuilt despite identical inputs');
  fs.writeFileSync(path.join(root, 'main.mbt'), 'fn main { println("changed source") }');
  fs.writeFileSync(path.join(root, 'js/app.ts'), 'console.log("changed frontend")');
  result = run();
  assert.equal(result.image, original, 'application source changed base key');
  assert.equal(built(result).length, 0);
  for (const input of inputs) {
    const file = path.join(root, input), content = fs.readFileSync(file);
    fs.appendFileSync(file, '\n');
    result = run();
    assert.equal(result.status, 0, result.stderr);
    assert.notEqual(result.image, original, input + ' did not invalidate base');
    assert.equal(built(result).length, 1);
    fs.writeFileSync(file, content);
  }
  const official = run({ DEBIAN_MIRROR: 'http://unused.invalid/debian' });
  assert.equal(official.image, original, 'inactive mirror changed official base key');
  for (const extra of [{ MOONBIT_VERSION: 'test-version' }, { DOCKER_DEFAULT_PLATFORM: 'linux/amd64' }, { USE_CN_MIRRORS: '1' }]) {
    result = run(extra);
    assert.equal(result.status, 0, result.stderr);
    assert.notEqual(result.image, original);
    assert.equal(built(result).length, 1);
  }
  const cn = run({ USE_CN_MIRRORS: '1' });
  for (const key of ['DEBIAN_MIRROR', 'DEBIAN_SECURITY_MIRROR']) {
    result = run({ USE_CN_MIRRORS: '1', [key]: 'http://mirror.example.invalid/debian' });
    assert.notEqual(result.image, cn.image, key + ' did not invalidate CN base');
  }
  result = run({ REBUILD_BASE: '1', PULL_IMAGES: '0' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.image, original);
  assert.ok(built(result)[0].includes('--no-cache'));
  assert.ok(!built(result)[0].includes('--pull'));
  result = run({ TEST_FAIL: '1', REBUILD_BASE: '1' });
  assert.notEqual(result.status, 0);
  assert.ok(!result.commands.some(a => a[0] === 'tag'), 'failed base build changed convenience alias');
  result = run({ MOONHUB_BASE_IMAGE: original });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.image, original);
  assert.equal(built(result).length, 0);
  assert.notEqual(run({ MOONHUB_BASE_IMAGE: 'missing:base' }).status, 0);
  assert.notEqual(run({ MOONHUB_BASE_IMAGE: original, REBUILD_BASE: '1' }).status, 0);
  result = run({ DOCKER_DEFAULT_PLATFORM: 'windows/amd64' });
  assert.notEqual(result.status, 0);
  assert.equal(built(result).length, 0);
  fs.unlinkSync(path.join(root, 'moon.mod'));
  result = run();
  assert.notEqual(result.status, 0);
  assert.equal(built(result).length, 0, 'missing fingerprint input silently reused a base');
  console.log('Base image tests passed: reuse, dependency-only invalidation, platform/source settings, refresh, failure safety and explicit local image.');
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
