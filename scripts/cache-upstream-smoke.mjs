// Opt-in acceptance against the actual HTTP service and unmodified upstream JS.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import { ActionRuntime } from '../runner/actions/runtime.mjs';

const config = JSON.parse(await fs.readFile(process.argv[2], 'utf8'));
// Keep setup-node's npm cache path stable across the two isolated jobs, while
// all data stays in the test fixture rather than the developer's real home.
const shared = path.resolve(config.workspace, '../..');
const home = path.join(shared, 'home'), npmCache = path.join(shared, 'npm-cache');
process.env.HOME = home;
process.env.NPM_CONFIG_CACHE = npmCache;
await fs.mkdir(home, { recursive: true });
process.env.MOONHUB_ACTION_ARTIFACT_TOKEN = config.token;
process.env.MOONHUB_ACTION_ARTIFACT_URL = config.server;
const runtime = new ActionRuntime({ ...config, node20: process.env.MOONHUB_CACHE_NODE20 || process.execPath });
const revision = '0400d5f644dc74513175e3cd8d07132dd4860809'; // actions/cache v4.2.4
async function run(suffix, inputs) {
  const uses = 'actions/cache' + suffix + '@' + revision;
  const result = await runtime.action(uses, inputs);
  assert.equal(result.code, 0, 'Upstream cache action failed: ' + uses);
  return result.outputs;
}
const payload = path.join(config.workspace, 'payload');
const setup = 'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020';
const tool = path.join(home, '.tool-cache', 'node', process.versions.node, process.arch);
await fs.mkdir(path.join(tool, 'bin'), { recursive: true });
try { await fs.symlink(process.execPath, path.join(tool, 'bin', 'node')); }
catch (error) { if (error.code !== 'EEXIST') throw error; }
await fs.writeFile(tool + '.complete', '');
await fs.writeFile(path.join(config.workspace, 'package.json'), JSON.stringify({name:'cache-acceptance',version:'1.0.0'}));
await fs.writeFile(path.join(config.workspace, 'package-lock.json'), JSON.stringify({name:'cache-acceptance',version:'1.0.0',lockfileVersion:3,packages:{}}));
const setupInputs = {'node-version': process.versions.node,cache:'npm','cache-dependency-path':'package-lock.json'};

if (config.phase === 'produce') {
  const outputs = await run('', { path: 'payload', key: 'upstream-cache-exact' });
  assert.equal(outputs['cache-hit'], undefined);
  await fs.mkdir(payload);
  // Incompressible data exercises a single Blob PUT above the artifact block
  // limit, without silently passing when the toolkit suppresses save failures.
  const bytes = randomBytes(9 * 1024 * 1024);
  await fs.writeFile(path.join(payload, 'data.bin'), bytes);
  await fs.writeFile(path.join(payload, '.hidden'), createHash('sha256').update(bytes).digest('hex'));
  assert.equal(await runtime.posts(), 0);
  const lookup = await run('/restore', { path: 'payload', key: 'upstream-cache-exact', 'lookup-only': 'true', 'fail-on-cache-miss': 'true' });
  assert.equal(lookup['cache-hit'], 'true');
  // Re-saving an immutable key is harmless and does not replace its data.
  await fs.writeFile(path.join(payload, 'data.bin'), 'must-not-overwrite');
  await run('/save', { path: 'payload', key: 'upstream-cache-exact' });
  const setupResult = await runtime.action(setup, setupInputs);
  assert.equal(setupResult.code, 0);
  assert.notEqual(setupResult.outputs['cache-hit'], 'true');
  await fs.mkdir(npmCache, { recursive: true });
  await fs.writeFile(path.join(npmCache, 'moonhub-acceptance'), 'embedded-cache-client');
  assert.equal(await runtime.posts(), 0);
} else {
  await fs.rm(npmCache, { recursive: true, force: true });
  const setupResult = await runtime.action(setup, setupInputs);
  assert.equal(setupResult.code, 0);
  assert.equal(setupResult.outputs['cache-hit'], 'true', 'setup-node embedded cache client did not restore');
  assert.equal(await fs.readFile(path.join(npmCache, 'moonhub-acceptance'), 'utf8'), 'embedded-cache-client');
  const exact = await run('/restore', { path: 'payload', key: 'upstream-cache-exact', 'fail-on-cache-miss': 'true' });
  assert.equal(exact['cache-hit'], 'true');
  const bytes = await fs.readFile(path.join(payload, 'data.bin'));
  assert.equal(bytes.length, 9 * 1024 * 1024);
  assert.equal(await fs.readFile(path.join(payload, '.hidden'), 'utf8'), createHash('sha256').update(bytes).digest('hex'));
  await fs.rm(payload, { recursive: true });
  const lookup = await run('/restore', { path: 'payload', key: 'upstream-cache-exact', 'lookup-only': 'true' });
  assert.equal(lookup['cache-hit'], 'true');
  await assert.rejects(fs.stat(payload), { code: 'ENOENT' });
  const prefix = await run('/restore', { path: 'payload', key: 'upstream-cache-new', 'restore-keys': 'absent-\nupstream-cache-', 'fail-on-cache-miss': 'true' });
  assert.equal(prefix['cache-hit'], 'false');
  assert.equal(prefix['cache-matched-key'], 'upstream-cache-exact');
  assert.equal((await fs.stat(path.join(payload, 'data.bin'))).size, bytes.length);
  const versionMiss = await run('/restore', { path: 'different-path', key: 'upstream-cache-exact' });
  assert.equal(versionMiss['cache-hit'], undefined);
  assert.equal(await runtime.posts(), 0);
}
console.log('Cache v4 upstream ' + config.phase + ' acceptance passed');
