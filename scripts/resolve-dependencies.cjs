const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// The pinned email release still ships moon.mod.json. New MoonBuild rejects
// that manifest before compilation; migrate only this downloaded dependency,
// leaving the application source and generated interfaces untouched.
function resolveDependencies(root, run = spawnSync) {
  const resolve = () => run('moon', ['tree', '--package'], {
    cwd: root, encoding: 'utf8', timeout: 120000,
  });
  let result = resolve();
  const directory = path.join(root, '.mooncakes', 'nexacodes', 'email');
  const legacy = path.join(directory, 'moon.mod.json');
  if (result.status !== 0 && fs.existsSync(legacy) &&
      /moon\.mod\.json[\s\S]*no longer supported/.test(result.stderr || '')) {
    const metadata = JSON.parse(fs.readFileSync(legacy, 'utf8'));
    if (metadata.name !== 'nexacodes/email' || metadata.version !== '0.1.0') {
      throw new Error('Unexpected legacy email dependency; refusing migration');
    }
    console.log('[dependencies] Migrating nexacodes/email@0.1.0 metadata for the pinned MoonBit toolchain');
    const migrated = run('moon', ['fmt'], { cwd: directory, encoding: 'utf8', timeout: 120000 });
    if (migrated.status !== 0) {
      throw new Error(migrated.stderr || migrated.error?.message || 'Email dependency migration failed');
    }
    result = resolve();
  }
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0) throw new Error(result.error?.message || 'MoonBit dependency resolution failed');
}
module.exports = { resolveDependencies };
if (require.main === module) {
  try { resolveDependencies(path.resolve(__dirname, '..')); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
