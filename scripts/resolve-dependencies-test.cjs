const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const { resolveDependencies } = require('./resolve-dependencies.cjs');

test('fresh legacy email is migrated before retry, while source remains unchanged', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-dependencies-'));
  try {
    const directory = path.join(root, '.mooncakes/nexacodes/email');
    fs.mkdirSync(directory, { recursive: true });
    const legacy = path.join(directory, 'moon.mod.json');
    fs.writeFileSync(legacy, JSON.stringify({ name: 'nexacodes/email', version: '0.1.0' }));
    fs.writeFileSync(path.join(root, 'main.mbt'), 'original');
    const commands = [];
    resolveDependencies(root, (command, args, options) => {
      commands.push([command, args, options.cwd]);
      if (commands.length === 1) return { status: 1, stderr: 'moon.mod.json is no longer supported' };
      if (commands.length === 2) {
        assert.equal(options.cwd, directory);
        assert.deepEqual(args, ['fmt']);
        fs.unlinkSync(legacy);
        fs.writeFileSync(path.join(directory, 'moon.mod'), 'name = "nexacodes/email"');
      }
      return { status: 0 };
    });
    assert.equal(commands.length, 3);
    assert.equal(fs.readFileSync(path.join(root, 'main.mbt'), 'utf8'), 'original');
    let calls = 0;
    resolveDependencies(root, () => { calls++; return { status: 0 }; });
    assert.equal(calls, 1);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('unrelated resolver failures and unexpected dependency identities fail closed', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-dependencies-'));
  try {
    const directory = path.join(root, '.mooncakes/nexacodes/email');
    fs.mkdirSync(directory, { recursive: true });
    fs.writeFileSync(path.join(directory, 'moon.mod.json'), JSON.stringify({ name: 'other/package', version: '0.1.0' }));
    assert.throws(() => resolveDependencies(root, () => ({ status: 1, stderr: 'moon.mod.json is no longer supported' })), /Unexpected legacy/);
    let calls = 0;
    assert.throws(() => resolveDependencies(root, () => { calls++; return { status: 1, stderr: 'download failed' }; }), /resolution failed/);
    assert.equal(calls, 1);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
