// Real privileged Docker/DinD acceptance. Run only on a dedicated validation
// host or Docker Desktop VM. This never mounts that host's Docker socket.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {spawn, execFileSync} = require('node:child_process');
const image = process.env.MOONHUB_LINUX_CI_IMAGE || 'moonhub-runner:linux-ci-dev';
const docker = (args, options = {}) => execFileSync('docker', args, {
  encoding: 'utf8', timeout: 120000, maxBuffer: 4 * 1024 * 1024, ...options,
});
function createRunnerFixture({token, cancel, containerMode = '', name, now = Date.now, runDocker = docker}) {
  const logs = [], events = []; let execution = '', sequence = 0, conclusion = '', started = 0, cancelReady = false, timeoutAt = 0, cleanupVerified = false, failure;
  const server = http.createServer(async (req, res) => {
    try {
      assert.equal(req.headers.authorization, 'Bearer ' + token);
      let source = ''; for await (const chunk of req) { source += chunk; assert.ok(source.length < 65536); }
      const body = JSON.parse(source), operation = req.url.split('/').at(-1);
      // A second clock read can make the lease exceed the protocol's 60000 ms limit.
      const time = now();
      const event = {operation, state: body.state, sequence: body.sequence};
      events.push(event);
      if (operation === 'artifact-runtime') {
        assert.equal(body.version, 1); assert.equal(body.execution_id, execution);
        assert.equal(body.origin, 'http://host.docker.internal:' + server.address().port);
        res.writeHead(200, {'Content-Type': 'application/json'});
        res.end(JSON.stringify({token: crypto.randomBytes(32).toString('hex'), results_url: body.origin, expires_ms: String(time + 300000)})); return;
      }
      if (operation === 'start') { execution = body.execution_id; started = time; }
      else if (operation === 'logs') {
        assert.equal(body.sequence, String(++sequence));
        assert.ok(!body.text.includes(token)); logs.push(body.text);
        if (body.text.includes('CI_DOCKER_READY')) { cancelReady = true; if (containerMode === 'timeout' && !timeoutAt) timeoutAt = time + 1500; }
      } else if (operation === 'complete') {
        conclusion = body.conclusion;
        if (containerMode) {
          for (const args of [['ps', '-aq'], ['network', 'ls', '-q'], ['image', 'ls', '-q']]) {
            assert.equal(runDocker(['exec', '--user', '0', name, 'docker', ...args, '--filter', 'label=io.moonhub.workflow=' + execution]).trim(), '', 'job resources survived completion');
          }
          cleanupVerified = true;
        }
      }
      else assert.ok(['heartbeat', 'steps'].includes(operation));
      const response = {version: 1, execution_id: execution, attempt_id: '1',
        state: conclusion ? 'completed' : 'running', server_time_ms: String(time),
        lease_until_ms: String(time + 60000), deadline_ms: String(timeoutAt || started + 300000),
        cancel_requested: cancel && cancelReady, log_sequence: String(sequence), conclusion};
      event.response = response;
      res.writeHead(200, {'Content-Type': 'application/json'});
      res.end(JSON.stringify(response));
    } catch (error) { failure = error; res.writeHead(500); res.end('fixture rejected request'); }
  });
  return {server, logs, events, get failure() { return failure; }, get conclusion() { return conclusion; }, get cleanupVerified() { return cleanupVerified; }};
}
async function scenario(cancel, containerMode = '') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-ci-smoke-'));
  const name = 'moonhub-ci-smoke-' + crypto.randomBytes(8).toString('hex');
  const token = crypto.randomBytes(32).toString('hex');
  const fixture = createRunnerFixture({token, cancel, containerMode, name});
  const {server, logs, events} = fixture;
  await new Promise(resolve => server.listen(0, '0.0.0.0', resolve));
  const script = [
    'test "$(id -u)" = 10001',
    'test "$(sudo -n id -u)" = 0',
    'libraries="$(ldconfig -p)"',
    'for library in libnspr4.so libnss3.so libnssutil3.so libsmime3.so libasound.so.2; do',
    '  grep -Fq "$library " <<< "$libraries" || { echo "Missing shared library: $library" >&2; exit 1; }',
    'done',
    'core_pattern="$(cat /proc/sys/kernel/core_pattern)"; sudo sysctl -w "kernel.core_pattern=$core_pattern" >/dev/null',
    'test ! -e /run/moonhub-runner/bootstrap.json',
    'sudo mkdir -p /usr/local/share/moonhub-probe',
    'sudo apt-get update -qq',
    'sudo apt-get install -y -qq --no-install-recommends jq',
    'test "$(jq -n 42)" = 42',
    'test -S /var/run/docker.sock',
    'test "$(docker info --format "{{.CgroupVersion}}")" = 2',
    'mkdir image; printf "FROM busybox:1.37\\nCOPY proof /proof\\n" > image/Dockerfile',
    'echo shared-workspace > image/proof',
    'docker pull busybox:1.37',
    'docker build -t ci-probe image',
    'docker run --rm ci-probe grep -q shared-workspace /proof',
    'node -e \'require("http").createServer((q,s)=>s.end("same-network")).listen(18789,"0.0.0.0")\' >/dev/null 2>&1 &',
    'docker run --rm --init --network host --ipc=host --memory 128m --cpus 0.5 --pids-limit 32 --volume "$GITHUB_WORKSPACE:$GITHUB_WORKSPACE" --workdir "$GITHUB_WORKSPACE" ci-probe sh -ec \'test "$(cat /sys/fs/cgroup/memory.max)" = 134217728; test "$(cat /sys/fs/cgroup/pids.max)" = 32; grep -q shared-workspace image/proof; wget -qO- http://127.0.0.1:18789 | grep -q same-network\'',
    ...(cancel ? ['docker run --detach --name ci-background busybox:1.37 sleep 120 >/dev/null'] : []),
    'echo CI_DOCKER_READY',
    ...(cancel ? ['sleep 120'] : ['echo CI_JOB_PASSED']),
  ].join('\n');
  const now = Date.now();
  const assignment = {version: 1, attempt_id: '1', run_id: '1', job_id: '1', repository: 'test/ci',
    commit_sha: 'a'.repeat(40), lease_until_ms: String(now + 60000), server_time_ms: String(now), state: 'leased',
    job: {id: 'ci', name: 'CI profile', runs_on: ['self-hosted', 'linux'], contents_read: false, timeout_minutes: 5,
      steps: [{id: 'probe', name: 'Probe', run: script, shell: 'bash', working_directory: '.', env: {}, timeout_minutes: 0}]}};
  if (containerMode) {
    const spec = (image, env = {}, options = []) => ({ image, env, options, ports: [] });
    const plan = { job: spec('postgres:16-bookworm'), services: { database: spec('postgres:16-bookworm', { POSTGRES_PASSWORD: 'fixture-password' }, ['--health-cmd', containerMode === 'startup' ? 'false' : 'pg_isready -U postgres', '--health-interval', '1s', '--health-retries', '3', '--health-timeout', '1s']) } };
    const step = (id, run, extra = {}) => ({ id, name: id, run, uses: '', remote: false, shell: '', working_directory: '.', env: {}, templates: run.includes('${{') ? { run } : {}, timeout_minutes: 0, ...extra });
    assignment.version = 16;
    assignment.job.context = { container_plan: JSON.stringify(plan), run_attempt: '1', ref: 'refs/heads/main' };
    assignment.job.steps = [
      step('probe', [
        'test "$(id -u)" = 0',
        'test ! -S /var/run/docker.sock',
        'test ! -e /control/assignment.json',
        'PGPASSWORD=fixture-password psql -h database -U postgres -c "CREATE TABLE probe (value int); INSERT INTO probe VALUES (42);"',
        'test "$(PGPASSWORD=fixture-password psql -h database -U postgres -Atc \'SELECT value FROM probe\')" = 42',
        'echo shared > proof',
        'echo NEXT_VALUE=shared >> "$GITHUB_ENV"',
        'mkdir action',
        'printf \'FROM busybox:1.37\\nCOPY entrypoint.sh /entrypoint.sh\\nRUN chmod +x /entrypoint.sh\\n\' > action/Dockerfile',
        'printf \'#!/bin/sh\\nset -eu\\ntest "$1" = "input with spaces"\\ntest "$NEXT_VALUE" = shared\\ngrep -q shared proof\\necho answer=42 >> "$GITHUB_OUTPUT"\\n\' > action/entrypoint.sh',
        'printf \'inputs:\\n  name: {default: fallback}\\nruns:\\n  using: docker\\n  image: Dockerfile\\n  entrypoint: /entrypoint.sh\\n  args: ["\\044{{ inputs.name }}"]\\n\' > action/action.yml',
      ].join('\n')),
      step('docker', '', { uses: './action', remote: true, inputs: { name: 'input with spaces' } }),
      step('image', '', { uses: 'docker://busybox:1.37', remote: true, inputs: { entrypoint: 'sh', args: '-ec \'test "$NEXT_VALUE" = shared; grep -q shared proof\'' } }),
      step('verify', 'test "${{ steps.docker.outputs.answer }}" = 42\necho CI_DOCKER_READY\n' + (containerMode === 'failure' ? 'exit 17' : cancel || containerMode === 'timeout' ? 'sleep 120' : 'echo CI_JOB_PASSED')),
    ];
  }
  const manifest = path.join(root, 'assignment.json'); fs.writeFileSync(manifest, JSON.stringify(assignment), {mode: 0o644});
  let timer;
  try {
    docker(['volume', 'create', '--label', 'io.moonhub.ci.smoke=1', name]);
    const child = spawn('docker', ['run', '--rm', '--interactive', '--name', name, '--privileged', '--cgroupns', 'private',
      '--memory', '3g', '--cpus', '2', '--pids-limit', '512', '--tmpfs', '/tmp:rw,exec,nosuid,nodev,size=1g',
      '--tmpfs', '/workspace:rw,exec,nosuid,nodev,size=128m,uid=10001,gid=10001,mode=0700',
      '--mount', 'type=bind,src=' + manifest + ',dst=/control/assignment.json,readonly',
      '--mount', 'type=volume,src=' + name + ',dst=/var/lib/docker',
      '--add-host', 'host.docker.internal:host-gateway', image, '--server', 'http://host.docker.internal:' + server.address().port,
      '--assignment', '/control/assignment.json', '--allow-http', '--linux-ci'], {stdio: ['pipe', 'pipe', 'pipe']});
    let output = '', diagnostic = '';
    child.stdout.on('data', chunk => { output += chunk; }); child.stderr.on('data', chunk => { diagnostic += chunk; });
    child.stdin.on('error', () => {}); child.stdin.end(token + '\n');
    timer = setTimeout(() => { try { docker(['rm', '-f', name]); } catch {} }, 360000);
    const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
    if (fixture.failure) throw fixture.failure;
    const expected = cancel ? 'cancelled' : containerMode === 'timeout' ? 'timed_out' : ['failure', 'startup'].includes(containerMode) ? 'failure' : 'success';
    assert.equal(code, expected === 'success' ? 0 : 1, diagnostic + '\n' + output + '\n' + JSON.stringify(events) + '\n' + logs.join(''));
    const report = JSON.parse(output.trim()); assert.equal(report.reported, true);
    assert.equal(report.conclusion, expected); assert.equal(fixture.conclusion, report.conclusion);
    if (containerMode !== 'startup') assert.ok(logs.join('').includes('CI_DOCKER_READY'));
    if (containerMode) assert.ok(fixture.cleanupVerified);
    assert.equal(docker(['ps', '-aq', '--filter', 'name=^' + name + '$']).trim(), '');
    console.log('LINUX_CI_' + (containerMode || 'native') + '_' + expected + '_OK');
  } finally {
    clearTimeout(timer); try { docker(['rm', '-f', name], {stdio: 'ignore'}); } catch {}
    docker(['volume', 'rm', name]);
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); fs.rmSync(root, {recursive: true, force: true});
  }
}
module.exports = {createRunnerFixture};
if (require.main === module) {
  (async () => { await scenario(false); await scenario(true);
    for (const mode of ['success', 'failure', 'startup', 'cancel', 'timeout']) await scenario(mode === 'cancel', mode); })().catch(error => {console.error(error); process.exitCode = 1;});
}
