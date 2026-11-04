const assert = require('node:assert/strict');
const os = require('node:os');
const { test } = require('node:test');
const { resolveDependencies } = require('./resolve-dependencies.cjs');

test('dependency resolution runs once in the module root', () => {
  const root = os.tmpdir();
  const commands = [];
  resolveDependencies(root, (command, args, options) => {
    commands.push([command, args, options]);
    return { status: 0 };
  });
  assert.deepEqual(commands, [['moon', ['tree', '--package'], {
    cwd: root, encoding: 'utf8', timeout: 120000,
  }]]);
});

test('resolver failures stop without attempting to migrate dependencies', () => {
  let calls = 0;
  assert.throws(() => resolveDependencies(os.tmpdir(), () => {
    calls++;
    return { status: 1, stderr: 'moon.mod.json is no longer supported' };
  }), /resolution failed/);
  assert.equal(calls, 1);
  assert.throws(() => resolveDependencies(os.tmpdir(), () => ({
    status: null, error: new Error('spawn moon ENOENT'),
  })), /spawn moon ENOENT/);
});
