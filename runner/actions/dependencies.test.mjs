import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { gzipSync } from 'node:zlib';
import { DependencyClient, sourceEnvironment } from './dependencies.mjs';
import { ActionRuntime } from './runtime.mjs';

async function fixture(t) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'moonhub-dependency-')));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const config = { workspace: path.join(root, 'workspace'), temp: path.join(root, 'temp'), repository: 'alice/demo', server: 'https://moonhub.test', sha: 'a'.repeat(40), node20: process.execPath };
  await fs.mkdir(config.workspace); await fs.mkdir(config.temp);
  return { root, config };
}
function git(cwd, ...args) { return execFileSync('git', ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', '-c', 'core.hooksPath=' + (process.platform === 'win32' ? 'NUL' : '/dev/null'), ...args], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim(); }

test('private action download credentials stay outside action processes and cached grants are rechecked', async t => {
  const { root, config } = await fixture(t);
  const source = path.join(root, 'action'); await fs.mkdir(source);
  await fs.writeFile(path.join(source, 'action.yml'), 'runs: {using: node24, main: main.cjs}\n');
  await fs.writeFile(path.join(source, 'main.cjs'), 'if (Object.keys(process.env).some(k=>k.startsWith("MOONHUB_ACTION_"))) throw Error("credential escaped");require("fs").appendFileSync(process.env.GITHUB_OUTPUT,"answer=42\\n");');
  git(source, 'init', '-q'); git(source, 'add', '.'); git(source, 'commit', '-qm', 'action');
  const sha = git(source, 'rev-parse', 'HEAD');
  const archive = gzipSync(execFileSync('git', ['archive', '--format=tar', '--prefix=action/', 'HEAD'], { cwd: source }));
  let allowed = true; const requests = [], token = 'b'.repeat(64);
  const dependencyFetch = async (url, options) => {
    assert.ok(url.startsWith('https://moonhub.test/-/runner-api/v1/dependencies/'));
    assert.equal(options.headers.Authorization, 'Bearer ' + token);
    assert.equal(options.redirect, 'error');
    const body = JSON.parse(options.body); assert.equal(body.repository, 'private/action'); assert.equal(body.ref, 'v1');
    requests.push(url.split('/').at(-1));
    if (!allowed) return new Response('{"private":false}');
    return new Response(url.endsWith('/resolve') ? JSON.stringify({ private: true, sha }) : archive);
  };
  const runtime = new ActionRuntime(config);
  runtime.dependency = new DependencyClient(config, token, config.server + '/-/runner-api/v1/dependencies', dependencyFetch);
  assert.equal((await runtime.action('private/action@v1')).outputs.answer, '42');
  assert.deepEqual(requests, ['resolve', 'archive']);
  allowed = false;
  await assert.rejects(runtime.action('private/action@v1'), /no longer current/);
  assert.deepEqual(requests, ['resolve', 'archive', 'resolve']);
});

test('full source bundles preserve ancestors and tags with exact URL rewrites', async t => {
  const { root, config } = await fixture(t);
  const source = path.join(root, 'source'); await fs.mkdir(source);
  git(source, 'init', '-q'); await fs.writeFile(path.join(source, 'file'), 'one'); git(source, 'add', '.'); git(source, 'commit', '-qm', 'one'); git(source, 'tag', 'v1.0.0');
  await fs.writeFile(path.join(source, 'file'), 'two'); git(source, 'commit', '-qam', 'two');
  const sha = git(source, 'rev-parse', 'HEAD'); git(source, 'update-ref', 'refs/heads/moonhub-source', sha);
  const file = path.join(root, 'source.bundle'); git(source, 'bundle', 'create', file, 'refs/heads/moonhub-source', '--tags');
  const bundle = await fs.readFile(file);
  const client = new DependencyClient(config, 'b'.repeat(64), config.server + '/-/runner-api/v1/dependencies', async (_, options) => {
    assert.deepEqual(JSON.parse(options.body), { repository: 'alice/demo', ref: sha, full_history: true });
    return new Response(bundle, { headers: { 'x-moonhub-commit': sha } });
  });
  const result = await client.source('alice/demo', sha, true, process.env);
  assert.equal(git(root, '--git-dir', result.git, 'rev-list', '--count', sha), '2');
  assert.match(git(root, '--git-dir', result.git, 'describe', '--tags', sha), /^v1.0.0-1-g/);
  await assert.rejects(fs.stat(path.join(result.git, 'shallow')), { code: 'ENOENT' });
  const env = { GIT_CONFIG_COUNT: '3', GIT_CONFIG_VALUE_0: config.server + '/alice/demo', GIT_CONFIG_VALUE_2: 'http://moonhub.localhost/alice/demo' };
  sourceEnvironment(env, result, config);
  assert.match(env.GIT_CONFIG_KEY_0, /source\.git\.insteadOf$/);
  assert.equal(env.GIT_CONFIG_VALUE_0, config.server + '/alice/demo');
  assert.equal(env.GIT_CONFIG_COUNT, '3');
});

test('dependency access errors and foreign origins fail closed', async t => {
  const { config } = await fixture(t);
  assert.throws(() => new DependencyClient(config, 'a'.repeat(64), 'https://other.test/dependencies'), /credential/);
  const client = new DependencyClient(config, 'a'.repeat(64), config.server + '/-/runner-api/v1/dependencies', async () => new Response('', { status: 403 }));
  await assert.rejects(client.resolve('other/action', 'v1'), /Dependency access failed \(403\)/);
  await assert.rejects(client.source('other/action', 'refs/heads/main', false, process.env), /403/);
});

test('checkout validates primary identity and a separate secondary path before executing code', async t => {
  const { config } = await fixture(t), runtime = new ActionRuntime(config);
  runtime.dependency = {};
  for (const inputs of [{ ref: 'moved' }, { repository: 'private/other', ref: 'refs/heads/main' }, { repository: 'private/other', ref: 'refs/heads/main', path: '../escape' }]) {
    await assert.rejects(runtime.javascript({ repository: 'actions/checkout' }, {}, inputs, {}, runtime.context(), {}, 'main'), /retain the run commit|separate path/);
  }
});

test('Git push credentials are URL scoped and invocation files disappear after success and failure', async t => {
  const { config } = await fixture(t);
  const runtime = new ActionRuntime({ ...config, api_permissions: 3 });
  runtime.dependency = {}; runtime.apiToken = 'e'.repeat(64);
  for (const outcome of [0, 17, 'throw']) {
    let directory;
    runtime.process = async (_, args, env) => {
      directory = path.dirname(env.GH_CONFIG_DIR);
      assert.ok(!args.some(value => value.includes(runtime.apiToken)));
      assert.equal(env.GIT_CONFIG_KEY_0, `http.${config.server}/-/api/v1/repos/alice/demo/git/.extraheader`);
      assert.equal(env.GIT_CONFIG_VALUE_0, 'Authorization: Bearer ' + runtime.apiToken);
      assert.equal(env.GIT_CONFIG_KEY_1, 'http.followRedirects');
      assert.equal(env.GIT_CONFIG_VALUE_1, 'false');
      if (outcome === 'throw') throw new Error('injected command failure');
      return outcome;
    };
    if (outcome === 'throw') await assert.rejects(runtime.script('exit 1', 'bash', '.'), /injected command failure/);
    else assert.equal((await runtime.script('exit 0', 'bash', '.')).code, outcome);
    await assert.rejects(fs.stat(directory), { code: 'ENOENT' });
    assert.ok(!JSON.stringify(runtime.state).includes(runtime.apiToken));
  }
});
