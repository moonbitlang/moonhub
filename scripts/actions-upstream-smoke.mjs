// Opt-in network acceptance: execute upstream code, never a built-in substitute.
// Run in the dependency-base Linux image, with this checkout mounted read-only.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { DependencyClient } from '../runner/actions/dependencies.mjs';
import { ActionRuntime } from '../runner/actions/runtime.mjs';
const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'moonhub-upstream-actions-'));
const workspace = path.join(root, 'workspace'), temp = path.join(root, 'temp'), home = path.join(root, 'home'), source = path.join(root, 'source.git');
const gitEnv = { PATH: process.env.PATH, HOME: home, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_TERMINAL_PROMPT: '0' };
const git = (...args) => execFileSync('git', ['-c', 'safe.directory=' + repositoryRoot.replace(/\/$/, ''), '-c', 'core.hooksPath=/dev/null', ...args], { encoding: 'utf8', env: gitEnv, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const oldHome = process.env.HOME;
try {
  await Promise.all([fs.mkdir(workspace), fs.mkdir(temp), fs.mkdir(home)]);
  git('init', '--bare', source);
  const sha = git('-C', repositoryRoot, 'rev-parse', 'HEAD');
  git('--git-dir', source, 'fetch', '--depth=1', '--no-tags', repositoryRoot, sha);
  git('--git-dir', source, 'update-ref', 'refs/heads/main', sha);
  process.env.HOME = home;
  const config = { workspace, temp, repository: 'compiler/moonhub', sha, server: 'https://moonhub.example', source_git: source, context: {ref: 'refs/heads/main'},
    ...(process.env.MOONHUB_ACTION_NODE20 ? {node20: process.env.MOONHUB_ACTION_NODE20} : {}) };
  const runtime = new ActionRuntime(config);
  const checkout = await runtime.action('actions/checkout@v6', {'persist-credentials': 'false'});
  assert.equal(checkout.code, 0); assert.equal(git('-C', workspace, 'rev-parse', 'HEAD'), sha);
  // Real, unchanged upstream checkout consumes the full-history and secondary
  // source transport. Authorization/pinning are covered by the native service
  // tests; this adapter returns the exact bundle response shape locally.
  const history = path.join(root, 'history'); await fs.mkdir(history);
  git('-C', history, 'init', '--quiet');
  await fs.writeFile(path.join(history, 'release.txt'), 'one'); git('-C', history, 'add', '.');
  const commit = message => git('-C', history, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qam', message);
  commit('first release'); git('-C', history, 'tag', 'v1.0.0');
  await fs.writeFile(path.join(history, 'release.txt'), 'two'); commit('release change');
  const fullSha = git('-C', history, 'rev-parse', 'HEAD'); git('-C', history, 'update-ref', 'refs/heads/moonhub-source', fullSha);
  const bundlePath = path.join(root, 'history.bundle'); git('-C', history, 'bundle', 'create', bundlePath, 'refs/heads/moonhub-source', '--tags');
  const bundle = await fs.readFile(bundlePath), fullWorkspace = path.join(root, 'full-workspace'); await fs.mkdir(fullWorkspace);
  const fullConfig = { ...config, workspace: fullWorkspace, sha: fullSha, source_git: undefined, api_permissions: 3 };
  const fullRuntime = new ActionRuntime(fullConfig, { actions: runtime.state.actions });
  fullRuntime.apiToken = 'd'.repeat(64); fullRuntime.state.masks.push(fullRuntime.apiToken);
  fullRuntime.dependency = new DependencyClient(fullConfig, 'a'.repeat(64), config.server + '/-/runner-api/v1/dependencies', async (url, options) => {
    if (url.endsWith('/resolve')) return new Response('{"private":false}');
    const request = JSON.parse(options.body);
    assert.ok(request.repository === config.repository && request.ref === fullSha || request.repository === 'private/dependency' && request.ref === 'refs/heads/main');
    return new Response(bundle, { headers: { 'x-moonhub-commit': fullSha } });
  });
  assert.equal((await fullRuntime.action('actions/checkout@v6', { 'fetch-depth': '0' })).code, 0);
  assert.equal(git('-C', fullWorkspace, 'rev-parse', 'HEAD'), fullSha);
  assert.ok(!git('-C', fullWorkspace, 'config', '--local', '--list').includes(fullRuntime.apiToken));
  assert.ok(!git('-C', fullWorkspace, 'config', '--local', '--list').includes(Buffer.from('x-access-token:' + fullRuntime.apiToken).toString('base64')));
  assert.equal(git('-C', fullWorkspace, 'remote', 'get-url', '--push', 'origin'), config.server + '/-/api/v1/repos/' + config.repository + '/git');
  assert.equal(git('-C', fullWorkspace, 'rev-list', '--count', 'HEAD'), '2');
  assert.match(git('-C', fullWorkspace, 'describe', '--tags'), /^v1.0.0-1-g/);
  assert.equal(git('-C', fullWorkspace, 'log', '--format=%s', 'v1.0.0..HEAD'), 'release change');
  assert.equal((await fullRuntime.action('actions/checkout@v6', { repository: 'private/dependency', ref: 'refs/heads/main', path: 'vendor/dependency', 'fetch-depth': '0' })).code, 0);
  assert.equal(git('-C', path.join(fullWorkspace, 'vendor/dependency'), 'rev-parse', 'HEAD'), fullSha);
  assert.equal(git('-C', fullWorkspace, 'rev-parse', 'HEAD'), fullSha);
  assert.equal(await fullRuntime.posts(), 0);
  // Avoid a second toolchain download; setup-node itself is the real upstream JS.
  const cache = path.join(home, '.tool-cache', 'node', process.versions.node, process.arch);
  await fs.mkdir(path.join(cache, 'bin'), {recursive: true});
  await fs.symlink(process.execPath, path.join(cache, 'bin/node')); await fs.writeFile(cache + '.complete', '');
  const setup = await runtime.action('actions/setup-node@v4', {'node-version': process.versions.node});
  assert.equal(setup.code, 0); assert.equal(setup.outputs['node-version'], 'v' + process.versions.node);
  assert.equal(await runtime.posts(), 0);
  console.log(JSON.stringify({ sha, checkout: checkout.code, setup: setup.code, output: setup.outputs['node-version'], resolved: Object.values(runtime.state.actions).map(a => ({repository:a.repository, ref:a.ref, commit:a.commit})) }, null, 2));
} finally {
  if (oldHome === undefined) delete process.env.HOME; else process.env.HOME = oldHome;
  await fs.rm(root, {recursive:true, force:true});
}
