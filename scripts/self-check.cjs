const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

// Archive checkouts have no Git index. Track both content and the file set so
// fmt/info cannot silently modify, remove, or introduce generated interfaces.
function snapshotInputs(root) {
  const ignored = new Set(['.git', '.mooncakes', '.moon', '.home', '.tmp', '.agents', '.codex', '_build', 'target', 'node_modules', 'assets']);
  const inputs = new Map();
  function visit(directory) {
    for (const entry of fs.readdirSync(path.join(root, directory), { withFileTypes: true })) {
      if (ignored.has(entry.name)) continue;
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(file);
      else if (entry.isFile() && (/\.mbt(?:i|\.md)?$/.test(entry.name) || /^moon\.(pkg|mod)(\.json)?$/.test(entry.name))) {
        inputs.set(file, crypto.createHash('sha256').update(fs.readFileSync(path.join(root, file))).digest('hex'));
      }
    }
  }
  visit('');
  return inputs;
}

function assertUnchanged(before, after) {
  const changed = [...new Set([...before.keys(), ...after.keys()])]
    .filter(file => before.get(file) !== after.get(file)).sort();
  assert.equal(changed.length, 0, 'moon fmt/info changed inputs:\n' + changed.join('\n'));
}

function main() {
  const root = path.resolve(__dirname, '..');
  const run = (command, args) => execFileSync(command, args, { cwd: root, stdio: 'inherit', timeout: 1800000 });
  run('moon', ['version', '--all']);
  const before = snapshotInputs(root);
  run('moon', ['check', '--deny-warn']);
  run('moon', ['fmt']);
  run('moon', ['info']);
  assertUnchanged(before, snapshotInputs(root));
  run(process.execPath, ['scripts/check-package-boundaries.cjs']);
  run(process.execPath, ['--test', 'scripts/self-check-test.cjs', 'scripts/pre-commit-hook-test.cjs']);
  run('npm', ['ci', '--prefix', 'js', '--no-audit', '--no-fund']);
  run('npm', ['run', 'build', '--prefix', 'js']);
  run('moon', ['test', '--target', 'native', '--strip', '-j', '1', '--deny-warn']);
  run('moon', ['build', '--target', 'native', '--strip', '-j', '1', '--deny-warn']);
  console.log('MOONHUB_SELF_CHECK_OK:' + (process.env.GITHUB_SHA || 'local'));
}

module.exports = { snapshotInputs, assertUnchanged };
if (require.main === module) main();
