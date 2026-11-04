const path = require('node:path');
const { spawnSync } = require('node:child_process');

function resolveDependencies(root, run = spawnSync) {
  const result = run('moon', ['tree', '--package'], {
    cwd: root, encoding: 'utf8', timeout: 120000,
  });
  // The dependency tree is useful for interactive diagnosis, but its repeated
  // transitive entries make CI logs thousands of lines long. Keep stderr for
  // failures and let the caller report the concise stage result.
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0) throw new Error(result.error?.message || 'MoonBit dependency resolution failed');
}
module.exports = { resolveDependencies };
if (require.main === module) {
  try { resolveDependencies(path.resolve(__dirname, '..')); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
