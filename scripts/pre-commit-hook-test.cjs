const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const hooks = path.resolve(__dirname, '../.githooks');

function fixture(t, options = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-hook-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const repo = path.join(root, 'repo');
  const bin = path.join(root, 'bin');
  const log = path.join(root, 'commands.jsonl');
  fs.mkdirSync(repo);
  fs.mkdirSync(bin);
  fs.mkdirSync(path.join(repo, 'subdirectory'));
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
  Object.assign(env, {
    PATH: `${bin}${path.delimiter}${env.PATH}`,
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    MOON_HOOK_LOG: log,
    MOON_HOOK_FAIL: options.fail || '',
    MOON_HOOK_MUTATE: options.mutate || '',
  });
  fs.writeFileSync(path.join(bin, 'moon'), `#!/usr/bin/env node
const fs = require('node:fs');
const command = process.argv[2];
fs.appendFileSync(process.env.MOON_HOOK_LOG, JSON.stringify({ args: process.argv.slice(2), cwd: process.cwd() }) + '\\n');
if (command === process.env.MOON_HOOK_FAIL) process.exit(9);
if (command === 'fmt' && process.env.MOON_HOOK_MUTATE === 'fmt') fs.appendFileSync('main.mbt', '// formatted\\n');
if (command === 'info' && process.env.MOON_HOOK_MUTATE === 'info') fs.writeFileSync('pkg.generated.mbti', '// generated interface\\n');
`, { mode: 0o755 });
  const git = (...args) => execFileSync('git', args, { cwd: repo, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  git('init', '-q');
  git('config', 'user.name', 'Hook Test');
  git('config', 'user.email', 'hook-test@moonhub.invalid');
  git('config', 'core.hooksPath', hooks);
  git('config', 'commit.gpgsign', 'false');
  fs.writeFileSync(path.join(repo, 'moon.mod'), 'name = "test/hooks"\n');
  fs.writeFileSync(path.join(repo, 'main.mbt'), '// staged code\n');
  git('add', '.');
  const commands = () => fs.existsSync(log)
    ? fs.readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line))
    : [];
  const commit = () => spawnSync('git', ['commit', '-m', 'fixture'], {
    cwd: path.join(repo, 'subdirectory'), env, encoding: 'utf8',
  });
  return { repo, git, commands, commit };
}

test('the actual Git hook runs check, fmt, info in order from the repository root', t => {
  const f = fixture(t);
  const result = f.commit();
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(f.commands().map(entry => entry.args), [['check', '--deny-warn'], ['fmt'], ['info']]);
  assert.ok(f.commands().every(entry => fs.realpathSync(entry.cwd) === fs.realpathSync(f.repo)));
  assert.equal(f.git('status', '--porcelain'), '');
});

for (const [fail, expected] of [
  ['check', [['check', '--deny-warn']]],
  ['fmt', [['check', '--deny-warn'], ['fmt']]],
  ['info', [['check', '--deny-warn'], ['fmt'], ['info']]],
]) {
  test(`failure in ${fail} stops the commit without advancing or changing the index`, t => {
    const f = fixture(t, { fail });
    const staged = f.git('diff', '--cached', '--binary');
    assert.notEqual(f.commit().status, 0);
    assert.deepEqual(f.commands().map(entry => entry.args), expected);
    assert.equal(f.git('diff', '--cached', '--binary'), staged);
    assert.throws(() => f.git('rev-parse', '--verify', 'HEAD'));
  });
}

for (const mutate of ['fmt', 'info']) {
  test(`${mutate} output must be reviewed and staged explicitly`, t => {
    const f = fixture(t, { mutate });
    const staged = f.git('diff', '--cached', '--binary');
    const result = f.commit();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /review and stage/);
    assert.equal(f.commands().length, 3);
    assert.equal(f.git('diff', '--cached', '--binary'), staged);
    if (mutate === 'info') {
      assert.match(f.git('ls-files', '--others', '--exclude-standard'), /pkg\.generated\.mbti/);
    } else {
      assert.match(f.git('diff', '--name-only'), /main\.mbt/);
    }
  });
}

test('unstaged tracked edits are rejected before formatting or checking another version', t => {
  const f = fixture(t);
  fs.appendFileSync(path.join(f.repo, 'main.mbt'), '// unstaged work\n');
  const staged = f.git('diff', '--cached', '--binary');
  assert.notEqual(f.commit().status, 0);
  assert.deepEqual(f.commands(), []);
  assert.equal(f.git('diff', '--cached', '--binary'), staged);
});

for (const name of ['extra.mbt', 'extra.mbt.md', 'extra.mbti', 'moon.pkg', 'moon.pkg.json', 'moon.mod', 'moon.mod.json']) {
  test(`untracked MoonBit input ${name} cannot influence validation`, t => {
    const f = fixture(t);
    fs.writeFileSync(path.join(f.repo, 'subdirectory', name), '// untracked input\n');
    const result = f.commit();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /new MoonBit inputs/);
    assert.deepEqual(f.commands(), []);
  });
}

test('untracked non-MoonBit notes do not prevent committing', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.repo, 'notes.txt'), 'untracked notes\n');
  assert.equal(f.commit().status, 0);
  assert.equal(f.commands().length, 3);
});
