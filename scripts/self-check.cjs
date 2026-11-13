const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { performance } = require('node:perf_hooks');

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

function runStage(name, command, args, { cwd, timeoutMs, progressMs = 30000, log = console.log, env = process.env }) {
  const started = performance.now();
  const elapsed = () => ((performance.now() - started) / 1000).toFixed(1) + 's';
  log(`[self-check] START ${name} (timeout ${timeoutMs / 1000}s)`);
  return new Promise((resolve, reject) => {
    // The runner uses Linux. A separate group lets a stage deadline stop npm's
    // child processes too, instead of leaving installers behind after failure.
    const child = spawn(command, args, { cwd, env, stdio: 'inherit', detached: true });
    let timedOut = false;
    const progress = setInterval(() => log(`[self-check] RUNNING ${name} (${elapsed()})`), progressMs);
    const timeout = setTimeout(() => {
      timedOut = true;
      if (child.pid) {
        try { process.kill(-child.pid, 'SIGKILL'); } catch (error) {
          if (error.code !== 'ESRCH') child.kill('SIGKILL');
        }
      }
    }, timeoutMs);
    const cleanup = () => { clearInterval(progress); clearTimeout(timeout); };
    child.once('error', error => {
      cleanup();
      log(`[self-check] FAIL ${name} (${elapsed()}): ${error.message}`);
      reject(error);
    });
    child.once('close', (code, signal) => {
      cleanup();
      if (!timedOut && code === 0) {
        log(`[self-check] PASS ${name} (${elapsed()})`);
        resolve();
      } else {
        const error = new Error(`${name}: ${timedOut ? 'timed out' : `exit ${code}, signal ${signal || 'none'}`} after ${elapsed()}`);
        log(`[self-check] FAIL ${error.message}`);
        reject(error);
      }
    });
  });
}

function compilerVersion(root, env) {
  const result = spawnSync('moonc', ['-v'], { cwd: root, env, encoding: 'utf8', timeout: 30000 });
  if (result.error || result.status !== 0) return undefined;
  return result.stdout.trim().match(/^v(\d+\.\d+\.\d+\+[a-zA-Z0-9]+(?:-[a-zA-Z0-9]+)*)(?:\s|$)/)?.[1];
}

async function toolchainEnvironment(root, { env = process.env, run = runStage } = {}) {
  // Local self-checks use the deployment pin. CI uses the toolchain selected by its workflow.
  // Never install through the image's shared library symlinks.
  const dockerfile = fs.readFileSync(path.join(root, 'deploy/base.Dockerfile'), 'utf8');
  const pins = [...dockerfile.matchAll(/^ARG MOONBIT_VERSION=(\d+\.\d+\.\d+\+[a-zA-Z0-9]+(?:-[a-zA-Z0-9]+)*)$/gm)];
  assert.equal(pins.length, 1, 'Expected one exact MOONBIT_VERSION pin in deploy/base.Dockerfile');
  const version = pins[0][1];
  if (env.CI === 'true') {
    assert.ok(compilerVersion(root, env), 'CI must select MoonBit before running self-check');
    return env;
  }
  if (compilerVersion(root, env) === version) return env;

  const home = path.join(root, '.tmp', 'self-check-moon', version);
  const selected = { ...env, MOON_HOME: home, PATH: path.join(home, 'bin') + path.delimiter + (env.PATH || '') };
  const receipt = path.join(home, '.moonhub-installed-version');
  const installed = fs.existsSync(receipt) && fs.readFileSync(receipt, 'utf8') === version;
  if (!installed || compilerVersion(root, selected) !== version) {
    fs.mkdirSync(home, { recursive: true });
    fs.rmSync(receipt, { force: true });
    await run('Pinned MoonBit toolchain', 'sh', ['deploy/install-moonbit.sh', version],
      { cwd: root, env: selected, timeoutMs: 300000 });
    assert.equal(compilerVersion(root, selected), version, 'Installed MoonBit compiler does not match the deployment pin');
    fs.writeFileSync(receipt, version);
  }
  return selected;
}

async function main() {
  const root = path.resolve(__dirname, '..');
  const env = { ...await toolchainEnvironment(root), MOONHUB_RELEASE_GH: '1' };
  const run = (name, command, args, timeoutMs = 300000) => runStage(name, command, args, { cwd: root, timeoutMs, env });
  await run('Toolchain versions', 'moon', ['version', '--all'], 30000);
  await run('Mooncakes index', 'moon', ['update']);
  await run('MoonBit dependencies', process.execPath, ['scripts/resolve-dependencies.cjs']);
  const before = snapshotInputs(root);
  await run('MoonBit check', 'moon', ['check', '--deny-warn']);
  await run('MoonBit format', 'moon', ['fmt']);
  await run('MoonBit interfaces', 'moon', ['info']);
  assertUnchanged(before, snapshotInputs(root));
  await run('Package boundaries', process.execPath, ['scripts/check-package-boundaries.cjs']);
  await run('Wasm CLI build', 'moon', ['build', '--target', 'wasm', '--strip', '-j', '1', '--deny-warn', 'cmd/moonhub']);
  await run('Wasm CLI tests', 'moon', ['test', '--target', 'wasm', '--strip', '-j', '1', '--deny-warn', 'cli', 'domain']);
  await run('Wasm CLI smoke', process.execPath, ['scripts/cli-wasm-smoke.cjs']);
  await run('Script tests', process.execPath, ['--test', 'scripts/self-check-test.cjs', 'scripts/pre-commit-hook-test.cjs', 'scripts/resolve-dependencies-test.cjs', 'scripts/github-ci-test.cjs', 'scripts/macos-guest-test.mjs']);
  await run('Production deployment regression', process.execPath, ['--test', 'scripts/production-deploy-test.cjs', 'scripts/production-dind-test.cjs', 'scripts/github-deploy-test.cjs']);
  await run('Storage SDK dependencies', 'npm', ['ci', '--prefix', 'storage/s3', '--ignore-scripts', '--no-audit', '--no-fund']);
  await run('Storage SDK tests', process.execPath, ['--test', 'storage/s3/backend.test.mjs']);
  await run('Action runtime dependencies', 'npm', ['ci', '--prefix', 'runner/actions', '--ignore-scripts', '--no-audit', '--no-fund']);
  await run('Action runtime tests', process.execPath, ['--test', 'runner/actions/runtime.test.mjs']);
  await run('npm dependencies', 'npm', ['ci', '--prefix', 'js', '--no-audit', '--no-fund']);
  await run('Frontend build', 'npm', ['run', 'build', '--prefix', 'js']);
  await run('Diff worker build', 'moon', ['build', '--target', 'native', '--strip', '-j', '1', '--deny-warn', 'cmd/moonhub-diff-worker']);
  await run('Native tests', 'moon', ['test', '--target', 'native', '--strip', '-j', '1', '--deny-warn'], 1200000);
  await run('Native build', 'moon', ['build', '--target', 'native', '--strip', '-j', '1', '--deny-warn'], 600000);
  await run('S3 storage integration', process.execPath, ['scripts/storage-s3-smoke.mjs'], 300000);
  await run('Managed runner lifecycle', process.execPath, ['scripts/managed-runner-smoke.cjs'], 240000);
  console.log('MOONHUB_SELF_CHECK_OK:' + (process.env.GITHUB_SHA || 'local'));
}

module.exports = { snapshotInputs, assertUnchanged, runStage, toolchainEnvironment };
if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
