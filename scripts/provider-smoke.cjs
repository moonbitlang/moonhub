const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const binary = path.resolve('_build/native/debug/build/moonhub.exe');
const providerToken = 'a'.repeat(64);
const attemptId = '9007199254740993';
const label = 'io.moonhub.pipeline.workspace=1';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function scenario(mode) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-provider-smoke-'));
  const stateFile = path.join(root, 'docker-state.json');
  const tokenFile = path.join(root, 'provider-token');
  const workspace = path.join(root, 'assignments');
  const docker = path.join(root, 'docker');
  fs.mkdirSync(workspace);
  fs.writeFileSync(tokenFile, providerToken, { mode: 0o600 });
  fs.writeFileSync(stateFile, JSON.stringify({ mode, calls: [], ready: false,
    volumes: { 'moonhub-workspace-stale': true, 'moonhub-workspace-unrelated': false },
    containers: { deadbeef: 'moonhub-pipeline-stale', feedface: 'unrelated' },
  }));
  fs.writeFileSync(docker, `#!${process.execPath}
const fs = require('node:fs');
const assert = require('node:assert/strict');
const file = ${JSON.stringify(stateFile)};
const args = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(file, 'utf8'));
const save = () => { fs.writeFileSync(file + '.tmp', JSON.stringify(state)); fs.renameSync(file + '.tmp', file); };
state.calls.push(args); save();
(async () => {
  if (args[0] === 'info' || args[0] === 'image') return;
  if (args[0] === 'ps') {
    assert.ok(args.includes('name=^moonhub-pipeline-'));
    console.log(Object.keys(state.containers).filter(id => state.containers[id].startsWith('moonhub-pipeline-')).join('\\n'));
    return;
  }
  if (args[0] === 'rm') {
    const id = Object.keys(state.containers).find(id => id === args[2] || state.containers[id] === args[2]);
    if (id) { delete state.containers[id]; save(); } else process.exitCode = 1;
    return;
  }
  if (args[0] === 'volume') {
    if (args[1] === 'ls') {
      const filter = args[args.indexOf('--filter') + 1];
      let names = Object.keys(state.volumes);
      if (filter === ${JSON.stringify('label=' + label)}) names = names.filter(name => state.volumes[name]);
      else { assert.ok(filter.startsWith('name=^')); names = names.filter(name => name === filter.slice(6, -1)); }
      console.log(names.join('\\n')); return;
    }
    const name = args.at(-1);
    if (args[1] === 'create') {
      assert.ok(args.includes(${JSON.stringify(label)}));
      assert.match(name, /^moonhub-workspace-9007199254740993-[a-f0-9]{32}$/);
      assert.equal(state.volumes[name], undefined, 'workspace was reused');
      if (state.mode === 'create-rejected') { process.exitCode = 125; return; }
      state.volumes[name] = true; state.created = name; save();
      if (state.mode === 'create-failure') { process.exitCode = 125; return; }
      if (state.mode === 'cancel-create') { state.ready = true; save(); setInterval(() => {}, 1000); return; }
      console.log(name); return;
    }
    if (args[1] === 'rm') {
      if (name === state.created && state.mode === 'cleanup-failure') { process.exitCode = 1; return; }
      if (Object.hasOwn(state.volumes, name)) { delete state.volumes[name]; save(); } else process.exitCode = 1;
      return;
    }
  }
  if (args[0] === 'run') {
    const mount = args.find(arg => arg.startsWith('type=volume,'));
    assert.equal(mount, 'type=volume,src=' + state.created + ',dst=/workspace');
    assert.ok(args.includes('--interactive')); assert.ok(!args.includes('--privileged'));
    state.manifest = JSON.parse(fs.readFileSync(${JSON.stringify(path.join(workspace, attemptId, 'assignment.json'))}, 'utf8'));
    let token = ''; for await (const chunk of process.stdin) token += chunk;
    assert.match(token, /^[a-f0-9]{64}\\n$/);
    state.attemptToken = token.trim(); state.runArgs = args;
    state.containers.cafebeef = 'moonhub-pipeline-' + ${JSON.stringify(attemptId)};
    state.ready = true; save();
    if (state.mode === 'cancel') { setInterval(() => {}, 1000); return; }
    if (state.mode === 'run-failure') { process.exitCode = 125; return; }
    delete state.containers.cafebeef; save();
    console.log(JSON.stringify({ reported: true, conclusion: 'success' })); return;
  }
  throw new Error('unexpected Docker command ' + args.join(' '));
})().catch(error => { console.error(error); process.exitCode = 1; });
`, { mode: 0o700 });
  let claims = 0;
  let claim;
  let failure;
  const server = http.createServer(async (req, res) => {
    try {
      assert.equal(req.url, '/-/runner-api/v1/claims');
      assert.equal(req.headers.authorization, 'Bearer ' + providerToken);
      let body = ''; for await (const chunk of req) body += chunk;
      const request = JSON.parse(body);
      assert.match(request.request_id, /^[a-f0-9]{32}$/);
      assert.match(request.attempt_token, /^[a-f0-9]{64}$/);
      claims++;
      if (claims === 1) claim = request;
      const now = Date.now();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ version: 1, assignment: claims === 1 ? {
        version: 1, attempt_id: attemptId, run_id: '1', job_id: '1', repository: 'alice/demo',
        commit_sha: 'a'.repeat(40), lease_until_ms: String(now + 60000), server_time_ms: String(now), state: 'leased',
        job: { id: 'build', name: 'Build', runs_on: ['self-hosted', 'linux'], timeout_minutes: 1,
          steps: [{ id: 'check', name: 'Check', run: 'true', shell: 'bash', working_directory: '.', env: {}, timeout_minutes: 0 }],
        },
      } : null }));
    } catch (error) { failure = error; res.writeHead(500); res.end('{}'); }
  });
  let child, closed, exit;
  let output = '';
  const state = () => JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  function start() {
    exit = null;
    child = spawn(binary, ['provider', '--server', `http://127.0.0.1:${server.address().port}`,
      '--runner-server', 'http://127.0.0.1:1', '--runner-image', 'moonhub:mock-runner',
      '--docker', docker, '--docker-host', 'unix:///var/run/docker.sock', '--workspace-root', workspace,
      '--poll-ms', '100', '--allow-http', '--token-file', tokenFile], { stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', data => { output += data; });
    child.stderr.on('data', data => { output += data; });
    closed = new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', (code, signal) => { exit = { code, signal }; resolve(); });
    });
  }
  async function until(predicate) {
    const deadline = Date.now() + 30000;
    while (!predicate()) {
      if (failure) throw failure;
      if (exit || Date.now() > deadline) throw new Error(`${mode}: provider stopped or timed out: ${output}`);
      await delay(50);
    }
  }
  async function stop() {
    if (!exit) child.kill('SIGTERM');
    const timer = setTimeout(() => child.kill('SIGKILL'), 20000);
    try { await closed; } finally { clearTimeout(timer); }
  }
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    start();
    if (mode === 'cleanup-failure') {
      await until(() => exit !== null);
      assert.notEqual(exit.code, 0);
      assert.equal(claims, 1, 'claimed again after failed cleanup');
      assert.equal(state().volumes[state().created], true);
      const next = state(); next.mode = 'success'; fs.writeFileSync(stateFile, JSON.stringify(next));
      start();
      await until(() => claims >= 2);
    } else if (mode.startsWith('cancel')) {
      await until(() => state().ready);
    } else {
      await until(() => claims >= 2);
    }
    await stop();
    if (failure) throw failure;
    const done = state();
    assert.deepEqual(done.volumes, { 'moonhub-workspace-unrelated': false });
    assert.deepEqual(done.containers, { feedface: 'unrelated' });
    assert.deepEqual(fs.readdirSync(workspace), []);
    if (done.runArgs) {
      assert.equal(done.attemptToken, claim.attempt_token);
      assert.equal(done.manifest.attempt_id, attemptId);
      for (const value of ['--read-only', '--interactive', '--cap-drop', 'ALL', 'no-new-privileges', '--pids-limit', '--memory', '--cpus']) assert.ok(done.runArgs.includes(value));
      assert.ok(!done.runArgs.some(arg => arg.startsWith('/workspace:')));
      assert.ok(!done.runArgs.join(' ').includes(providerToken));
    }
    console.log(`Provider ${mode} smoke passed: private disk volume lifecycle, scoped recovery and constrained jobs.`);
  } finally {
    if (child && !exit) await stop();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  }
}
(async () => {
  for (const mode of ['success', 'run-failure', 'create-rejected', 'create-failure', 'cancel', 'cancel-create', 'cleanup-failure']) await scenario(mode);
})().catch(error => { console.error(error); process.exitCode = 1; });
