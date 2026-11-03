const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { snapshotInputs, assertUnchanged, runStage, toolchainEnvironment } = require('./self-check.cjs');

test('cold jobs initialize the registry before check and stop at the first failure', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-self-check-'));
  try {
    fs.mkdirSync(path.join(root, 'scripts'));
    fs.mkdirSync(path.join(root, 'bin'));
    fs.mkdirSync(path.join(root, 'deploy'));
    fs.copyFileSync(path.join(__dirname, '../deploy/base.Dockerfile'), path.join(root, 'deploy/base.Dockerfile'));
    const pin = fs.readFileSync(path.join(root, 'deploy/base.Dockerfile'), 'utf8').match(/^ARG MOONBIT_VERSION=(.+)$/m)[1];
    fs.writeFileSync(path.join(root, 'bin/moonc'), '#!/bin/sh\necho "v' + pin + ' (test)"\n', { mode: 0o755 });
    fs.copyFileSync(path.join(__dirname, 'self-check.cjs'), path.join(root, 'scripts/self-check.cjs'));
    fs.copyFileSync(path.join(__dirname, 'resolve-dependencies.cjs'), path.join(root, 'scripts/resolve-dependencies.cjs'));
    const log = path.join(root, 'commands');
    fs.writeFileSync(path.join(root, 'bin/moon'), `#!/bin/sh
printf '%s\\n' "$*" >> "$TEST_LOG"
case "$1" in
  version) exit 0 ;;
  update) touch "$TEST_LOG.registry" ;;
  tree) test -f "$TEST_LOG.registry" || exit 99 ;;
  check) test -f "$TEST_LOG.registry" || exit 99; exit 7 ;;
  *) exit 98 ;;
esac
`, { mode: 0o755 });
    const result = spawnSync(process.execPath, ['scripts/self-check.cjs'], {
      cwd: root, encoding: 'utf8',
      env: { ...process.env, TEST_LOG: log, PATH: path.join(root, 'bin') + ':' + process.env.PATH },
    });
    assert.notEqual(result.status, 0);
    assert.deepEqual(fs.readFileSync(log, 'utf8').trim().split('\n'), ['version --all', 'update', 'tree --package', 'check --deny-warn']);
    assert.match(result.stderr, /MoonBit check: exit 7/);
    assert.match(result.stdout, /START Mooncakes index/);
    assert.match(result.stdout, /PASS Mooncakes index \(\d+\.\ds\)/);
    assert.match(result.stdout, /FAIL MoonBit check/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('stages report progress and terminate a stalled process group at the deadline', async () => {
  const messages = [];
  await assert.rejects(runStage('Stalled download', process.execPath,
    ['-e', "require('node:child_process').spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'inherit' }); setInterval(() => {}, 1000)"],
    { cwd: os.tmpdir(), timeoutMs: 250, progressMs: 50, log: message => messages.push(message) }), /Stalled download: timed out/);
  assert.ok(messages.some(message => message.includes('RUNNING Stalled download')));
  assert.ok(messages.at(-1).includes('FAIL Stalled download: timed out'));
});

test('stage startup failures are reported and reject immediately', async () => {
  const messages = [];
  await assert.rejects(runStage('Missing tool', '/nonexistent-moonhub-test-command', [],
    { cwd: os.tmpdir(), timeoutMs: 10000, log: message => messages.push(message) }), /ENOENT/);
  assert.ok(messages.some(message => message.includes('FAIL Missing tool')));
});

test('archive inputs detect content changes and added/deleted interfaces without Git', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-self-check-'));
  try {
    fs.writeFileSync(path.join(root, 'moon.mod'), 'name = "test/self"\n');
    fs.writeFileSync(path.join(root, 'main.mbt'), 'fn main {}\n');
    fs.mkdirSync(path.join(root, 'package'));
    const api = path.join(root, 'package/pkg.generated.mbti');
    fs.writeFileSync(api, 'pub fn main() -> Unit\n');
    const before = snapshotInputs(root);
    assertUnchanged(before, snapshotInputs(root));
    fs.appendFileSync(path.join(root, 'main.mbt'), '\n');
    assert.throws(() => assertUnchanged(before, snapshotInputs(root)), /main\.mbt/);
    fs.writeFileSync(path.join(root, 'main.mbt'), 'fn main {}\n');
    fs.unlinkSync(api);
    assert.throws(() => assertUnchanged(before, snapshotInputs(root)), /pkg\.generated\.mbti/);
    fs.writeFileSync(api, 'pub fn main() -> Unit\n');
    fs.writeFileSync(path.join(root, 'package/extra.mbti'), '');
    assert.throws(() => assertUnchanged(before, snapshotInputs(root)), /extra\.mbti/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('archive checks ignore generated builds, dependency trees and runner HOME', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-self-check-'));
  try {
    fs.writeFileSync(path.join(root, 'main.mbt'), 'fn main {}\n');
    const before = snapshotInputs(root);
    for (const name of ['_build', '.mooncakes', '.home', '.tmp', 'node_modules', 'assets']) {
      fs.mkdirSync(path.join(root, name));
      fs.writeFileSync(path.join(root, name, 'generated.mbt'), 'ignored');
    }
    assertUnchanged(before, snapshotInputs(root));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

for (const mode of ['install', 'failure', 'wrong-version']) {
  test(`a mismatched runner uses an isolated pinned toolchain: ${mode}`, async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-toolchain-'));
    try {
      fs.mkdirSync(path.join(root, 'deploy'));
      fs.mkdirSync(path.join(root, 'shared/bin'), { recursive: true });
      fs.mkdirSync(path.join(root, 'shared/lib'));
      fs.writeFileSync(path.join(root, 'shared/lib/keep'), 'shared library');
      fs.writeFileSync(path.join(root, 'deploy/base.Dockerfile'), 'ARG MOONBIT_VERSION=0.10.19+testpin-nightly\n');
      const compiler = path.join(root, 'shared/bin/moonc');
      const oldCompiler = '#!/bin/sh\necho "v0.10.15+old (test)"\n';
      fs.writeFileSync(compiler, oldCompiler, { mode: 0o755 });
      const env = { ...process.env, CI: '', MOON_HOME: path.join(root, 'shared'), PATH: path.join(root, 'shared/bin') + ':' + process.env.PATH };
      let installs = 0;
      const run = async (name, command, args, options) => {
        installs++;
        assert.equal(command, 'sh');
        assert.deepEqual(args, ['deploy/install-moonbit.sh', '0.10.19+testpin-nightly']);
        assert.equal(options.env.HOME, env.HOME);
        assert.equal(options.env.MOON_HOME, path.join(root, '.tmp/self-check-moon/0.10.19+testpin-nightly'));
        assert.equal(options.env.PATH.split(path.delimiter)[0], path.join(options.env.MOON_HOME, 'bin'));
        if (mode === 'failure') throw new Error('Download failed');
        fs.mkdirSync(path.join(options.env.MOON_HOME, 'bin'), { recursive: true });
        const version = mode === 'wrong-version' ? '0.10.15+old' : '0.10.19+testpin-nightly';
        fs.writeFileSync(path.join(options.env.MOON_HOME, 'bin/moonc'), '#!/bin/sh\necho "v' + version + ' (test)"\n', { mode: 0o755 });
      };
      if (mode === 'install') {
        const selected = await toolchainEnvironment(root, { env, run });
        assert.equal(installs, 1);
        // Child processes (including npm) must inherit the same compiler/home.
        const result = await runStage('Selected toolchain', process.execPath,
          ['-e', `const {execFileSync}=require('node:child_process'); if (!execFileSync('moonc',['-v'],{encoding:'utf8'}).startsWith('v0.10.19+testpin-nightly ')) process.exit(8); if (process.env.MOON_HOME !== ${JSON.stringify(selected.MOON_HOME)}) process.exit(9);`],
          { cwd: root, env: selected, timeoutMs: 30000, log: () => {} });
        assert.equal(result, undefined);
        assert.deepEqual(await toolchainEnvironment(root, { env, run }), selected);
        assert.equal(installs, 1, 'reuse a verified installation');
        fs.writeFileSync(path.join(selected.MOON_HOME, 'bin/moonc'), oldCompiler, { mode: 0o755 });
        await toolchainEnvironment(root, { env, run });
        assert.equal(installs, 2, 'repair a cached compiler that no longer matches');
      } else {
        await assert.rejects(toolchainEnvironment(root, { env, run }), mode === 'failure' ? /Download failed/ : /does not match/);
        assert.equal(fs.existsSync(path.join(root, '.tmp/self-check-moon/0.10.19+testpin-nightly/.moonhub-installed-version')), false);
      }
      assert.equal(fs.readFileSync(compiler, 'utf8'), oldCompiler);
      assert.equal(fs.readFileSync(path.join(root, 'shared/lib/keep'), 'utf8'), 'shared library');
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
  });
}

for (const version of ['0.10.17+093cb8f9c', '0.10.18+fd7c30161-nightly']) {
  test(`CI keeps the workflow-selected MoonBit toolchain: ${version}`, async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-ci-moonbit-'));
    try {
      fs.mkdirSync(path.join(root, 'deploy'));
      fs.mkdirSync(path.join(root, 'nightly/bin'), { recursive: true });
      fs.writeFileSync(path.join(root, 'deploy/base.Dockerfile'), 'ARG MOONBIT_VERSION=0.10.17+testpin\n');
      fs.writeFileSync(path.join(root, 'nightly/bin/moonc'), '#!/bin/sh\necho "v' + version + ' (2026-11-02)"\n', { mode: 0o755 });
      const env = {
        ...process.env,
        CI: 'true',
        MOON_HOME: path.join(root, 'nightly'),
        PATH: path.join(root, 'nightly/bin') + path.delimiter + process.env.PATH,
      };
      let installs = 0;
      const selected = await toolchainEnvironment(root, {
        env,
        run: async () => { installs++; throw new Error('CI must not reinstall the deployment pin'); },
      });
      assert.equal(selected, env);
      assert.equal(installs, 0);
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
  });
}
