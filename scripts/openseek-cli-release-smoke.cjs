const assert = require('node:assert/strict');
const { execFileSync, spawn, spawnSync } = require('node:child_process');
const { createHash, randomBytes } = require('node:crypto');
const { once } = require('node:events');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const { pipeline } = require('node:stream/promises');
const { setTimeout: delay } = require('node:timers/promises');

const root = path.resolve(__dirname, '..');
const binary = path.resolve(process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/moonhub.exe'));
const diffWorker = path.resolve(process.env.MOONHUB_DIFF_WORKER
  || path.join(root, '_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe'));
const sha = 'dbe424220ddf20a9a78312850a7d6d801c7b9831';
const workflow = '.github/workflows/cli-release.yml';
const repo = 'root/openseek';
const api = '/-/api/v1/repos/' + repo;
const job = 'build[1]';
const platform = 'linux-x64';
const labels = ['self-hosted', 'linux', 'x64', 'ubuntu-22.04'];

async function main(source, image) {
  assert.ok(source && image, 'Usage: node scripts/openseek-cli-release-smoke.cjs BARE_OPENSEEK_REPO UBUNTU_AMD64_IMAGE');
  const sourceDir = path.resolve(source);
  const original = execFileSync('git', ['--git-dir=' + sourceDir, 'show', sha + ':' + workflow], { encoding: 'utf8' });
  fs.accessSync(binary, fs.constants.X_OK);
  fs.accessSync(diffWorker, fs.constants.X_OK);
  const directory = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-cli-release-')));
  const repos = path.join(directory, 'repos');
  const database = path.join(directory, 'moonhub.db');
  const env = { PATH: process.env.PATH, DB_PATH: database, MAIL_OUTBOX_DIR: path.join(directory, 'mail'),
    MOONHUB_DIFF_WORKER: diffWorker };
  const container = path.basename(directory).toLowerCase();
  const cli = args => execFileSync(binary, args, { cwd: directory, env, encoding: 'utf8', timeout: 30000 });
  const docker = (args, options = {}) => execFileSync('docker', args, {
    encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024, ...options,
  });
  let server, base, cookie, containerStarted = false;

  async function request(route, { body, token, status = 200 } = {}) {
    const response = await fetch(base + route, {
      method: body === undefined ? 'GET' : 'POST',
      headers: {
        ...(cookie && !token && { Cookie: cookie }),
        ...(token && { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' }),
      },
      body: token && body !== undefined ? JSON.stringify(body) : body,
      redirect: 'manual',
      signal: AbortSignal.timeout(120000),
    });
    const session = response.headers.get('set-cookie');
    if (session) cookie = session.split(';')[0];
    if (response.status !== status) {
      const detail = route.startsWith(api) ? ': ' + (await response.text()).slice(0, 4000) : '';
      throw new Error(route + ' returned ' + response.status + detail);
    }
    return response;
  }

  function register(name, providerLabels) {
    const token = randomBytes(32).toString('hex');
    const file = path.join(directory, name + '.token');
    fs.writeFileSync(file, token, { mode: 0o600 });
    cli(['pipeline-provider-create', '--name', name, '--token-file', file,
      '--labels', providerLabels.join(','), '--repositories', repo, '--admin', 'root']);
    return token;
  }

  async function claim(provider) {
    const token = randomBytes(32).toString('hex');
    const response = await request('/-/runner-api/v1/claims', {
      token: provider, body: { version: 1, request_id: randomBytes(16).toString('hex'), attempt_token: token },
    });
    return { assignment: (await response.json()).assignment, token };
  }

  try {
    const probe = JSON.parse(docker(['run', '--rm', '--platform', 'linux/amd64', '--network', 'none',
      image, '--probe-environment']));
    assert.equal(probe.architecture, 'x64');
    assert.match(probe.os_release, /^ID=ubuntu$/m);
    assert.match(probe.os_release, /^VERSION_ID="?22\.04"?$/m);
    fs.cpSync(path.join(root, 'db'), path.join(directory, 'db'), { recursive: true });
    fs.mkdirSync(repos);
    const password = randomBytes(24).toString('hex');
    const passwordFile = path.join(directory, 'password');
    fs.writeFileSync(passwordFile, password, { mode: 0o600 });
    const host = process.platform === 'linux'
      ? docker(['network', 'inspect', 'bridge', '--format', '{{(index .IPAM.Config 0).Gateway}}']).trim()
      : '127.0.0.1';
    assert.ok(net.isIPv4(host), 'Docker bridge needs an IPv4 gateway');
    const listener = net.createServer();
    listener.listen(0, host);
    await once(listener, 'listening');
    const { port } = listener.address();
    await new Promise(resolve => listener.close(resolve));
    base = `http://${host}:${port}`;
    const log = fs.openSync(path.join(directory, 'server.log'), 'w+', 0o600);
    try {
      server = spawn(binary, [repos, '--assets', path.join(root, 'assets'), '--host', host,
        '--port', String(port), '--root-user', 'root', '--root-password-file', passwordFile], {
        cwd: directory, env, stdio: ['ignore', log, log],
      });
    } finally {
      fs.closeSync(log);
    }
    for (let retries = 0; ; retries++) {
      try { await request('/-/login'); break; }
      catch (error) {
        if (retries === 100 || server.exitCode !== null) {
          throw new Error(fs.readFileSync(path.join(directory, 'server.log'), 'utf8'), { cause: error });
        }
        await delay(100);
      }
    }
    await request('/-/login', { body: new URLSearchParams({ name_key: 'root', password }), status: 303 });
    await request('/-/change-password', { body: new URLSearchParams({
      new_password: password, confirm_password: password,
    }), status: 303 });
    cli(['repo-create', repo, '--root', repos]);
    execFileSync('git', ['--git-dir=' + path.join(repos, repo + '.git'),
      'fetch', '--no-tags', '--update-shallow', sourceDir, sha + ':refs/heads/main'], { timeout: 30000 });
    const settings = '/-/settings/tokens';
    const form = await (await request(settings)).text();
    const csrf = form.match(/name="csrf_token" value="([^"]+)"/)?.[1];
    assert.ok(csrf, 'missing access-token form');
    const created = await (await request(settings, { body: new URLSearchParams({
      csrf_token: csrf, name: 'CLI release smoke', permission: 'execute', days: '1',
    }) })).text();
    const execute = created.match(/value="(mh_[a-f0-9]{64})"/)?.[1];
    assert.ok(execute, 'missing disposable execute token');
    const otherUbuntu = register('ubuntu-2404-x64', ['self-hosted', 'linux', 'x64', 'ubuntu-24.04']);
    const run = await (await request(api + '/runs', {
      token: execute, body: { branch: 'main', workflow, jobs: [job] },
    })).json();
    assert.equal(run.commit_sha, sha);
    const db = new DatabaseSync(database, { readOnly: true });
    try {
      const snapshot = db.prepare('SELECT workflow_source, definition_json FROM pipeline_run').get();
      assert.equal(snapshot.workflow_source, original);
      const jobs = JSON.parse(snapshot.definition_json).jobs;
      assert.deepEqual(jobs.map(row => [row.id, row.matrix.platform]), [[job, platform]]);
      const updates = await (await request(`/${repo}/pipelines/${run.number}/updates`)).json();
      assert.equal(updates.jobs.length, 1);
      assert.equal(updates.jobs[0].reason,
        'No authorized provider matches all required job labels.');
      assert.equal((await claim(otherUbuntu)).assignment, null);

      const ubuntu = register('ubuntu-2204-x64', labels);
      const { assignment, token } = await claim(ubuntu);
      assert.ok(assignment, 'Ubuntu 22.04 x64 provider did not get the selected job');
      assert.equal(assignment.job.id, job);
      assert.equal(assignment.job.matrix.platform, platform);
      assert.equal(assignment.commit_sha, sha);
      assert.deepEqual(assignment.job.runs_on, labels);
      const manifest = path.join(directory, 'assignment.json');
      fs.writeFileSync(manifest, JSON.stringify(assignment), { mode: 0o644 });
      console.log('Running pinned OpenSeek linux-x64 build on Ubuntu 22.04');
      containerStarted = true;
      const result = spawnSync('docker', ['run', '--rm', '--platform', 'linux/amd64', '--interactive', '--name', container,
        '--read-only', '--cap-drop=ALL', '--security-opt', 'no-new-privileges',
        '--tmpfs', '/tmp:rw,exec,nosuid,nodev,size=1g',
        '--tmpfs', '/workspace:rw,exec,nosuid,nodev,size=4g,uid=10001,gid=10001,mode=0700',
        '--mount', 'type=bind,src=' + manifest + ',dst=/control/assignment.json,readonly',
        '--add-host', 'host.docker.internal:host-gateway', image, '--server', `http://host.docker.internal:${port}`,
        '--assignment', '/control/assignment.json', '--allow-http',
      ], { input: token + '\n', encoding: 'utf8', timeout: 31 * 60000, maxBuffer: 4 * 1024 * 1024 });
      if (result.error) throw result.error;
      if (result.status !== 0) {
        const logs = db.prepare('SELECT content FROM pipeline_log_chunk WHERE attempt_id = ? ORDER BY sequence')
          .all(assignment.attempt_id).map(row => row.content).join('');
        throw new Error(result.stdout + result.stderr + logs.slice(-24000));
      }
      const report = JSON.parse(result.stdout.trim());
      assert.equal(report.conclusion, 'success');
      assert.equal(report.reported, true);
      assert.deepEqual(report.steps.map(step => step.state), ['success', 'skipped', 'skipped', 'success', 'success', 'success']);
      const completed = await (await request(api + '/runs/' + run.number, { token: execute })).json();
      assert.equal(completed.run.conclusion, 'success');

      const artifact = db.prepare("SELECT id, name, state FROM pipeline_artifact WHERE attempt_id = ? AND kind = 'artifact'")
        .get(assignment.attempt_id);
      assert.ok(artifact, 'missing CLI build artifact');
      assert.equal(artifact.name, 'cli-' + platform);
      assert.equal(artifact.state, 'ready');
      const download = await request(`/${repo}/actions/runs/${run.number}/artifacts/${artifact.id}`);
      const zip = path.join(directory, 'artifact.zip');
      await pipeline(download.body, fs.createWriteStream(zip, { mode: 0o600 }));
      const packageName = 'openseek-' + platform;
      const archive = path.join(directory, packageName + '.tar.gz');
      const unpack = (program, args) => execFileSync(program, args, { maxBuffer: 128 * 1024 * 1024, timeout: 30000 });
      const compressed = unpack('unzip', ['-p', zip, path.basename(archive)]);
      fs.writeFileSync(archive, compressed);
      const checksum = createHash('sha256').update(compressed).digest('hex');
      assert.equal(unpack('unzip', ['-p', zip, 'SHA256SUMS-' + platform]).toString().trim(),
        checksum + '  ' + path.basename(archive));
      for (const name of ['openseek', 'openseek-app-server']) {
        const executable = unpack('tar', ['-xOzf', archive, packageName + '/bin/' + name]);
        assert.deepEqual([...executable.subarray(0, 6)], [0x7f, 0x45, 0x4c, 0x46, 2, 1], name + ' needs ELF64 LE');
        assert.equal(executable.readUInt16LE(18), 62, name + ' needs x86-64');
      }
      console.log(`OpenSeek CLI artifact passed on Ubuntu 22.04 x64 (SHA-256 ${checksum})`);
    } finally {
      db.close();
    }
  } finally {
    if (containerStarted) spawnSync('docker', ['rm', '-f', container], { stdio: 'ignore', timeout: 30000 });
    if (server?.pid && server.exitCode === null && server.signalCode === null) {
      const done = once(server, 'exit');
      const timer = setTimeout(() => server.kill('SIGKILL'), 5000);
      server.kill('SIGTERM');
      try { await done; } finally { clearTimeout(timer); }
    }
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

main(...process.argv.slice(2)).catch(error => {
  console.error(error);
  process.exitCode = 1;
});
