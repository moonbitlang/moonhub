const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { snapshotInputs, assertUnchanged } = require('./self-check.cjs');

test('cold jobs initialize the registry before check and stop at the first failure', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-self-check-'));
  try {
    fs.mkdirSync(path.join(root, 'scripts'));
    fs.mkdirSync(path.join(root, 'bin'));
    fs.copyFileSync(path.join(__dirname, 'self-check.cjs'), path.join(root, 'scripts/self-check.cjs'));
    const log = path.join(root, 'commands');
    fs.writeFileSync(path.join(root, 'bin/moon'), `#!/bin/sh
printf '%s\\n' "$*" >> "$TEST_LOG"
case "$1" in
  version) exit 0 ;;
  update) touch "$TEST_LOG.registry" ;;
  check) test -f "$TEST_LOG.registry" || exit 99; exit 7 ;;
  *) exit 98 ;;
esac
`, { mode: 0o755 });
    const result = spawnSync(process.execPath, ['scripts/self-check.cjs'], {
      cwd: root, encoding: 'utf8',
      env: { ...process.env, TEST_LOG: log, PATH: path.join(root, 'bin') + ':' + process.env.PATH },
    });
    assert.notEqual(result.status, 0);
    assert.deepEqual(fs.readFileSync(log, 'utf8').trim().split('\n'), ['version --all', 'update', 'check --deny-warn']);
    assert.match(result.stderr, /status: 7/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
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
