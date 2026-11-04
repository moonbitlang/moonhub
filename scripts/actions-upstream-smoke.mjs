// Opt-in network acceptance: execute upstream code, never a built-in substitute.
// Run in the dependency-base Linux image, with this checkout mounted read-only.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
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
