const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { snapshotInputs, assertUnchanged } = require('./self-check.cjs');

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
