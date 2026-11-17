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
async function scenario(cancel) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-ci-smoke-'));
  const name = 'moonhub-ci-smoke-' + crypto.randomBytes(8).toString('hex');
  const token = crypto.randomBytes(32).toString('hex');
  const logs = [], events = []; let execution = '', sequence = 0, conclusion = '', started = 0, cancelReady = false, failure;
  const server = http.createServer(async (req, res) => {
    try {
      assert.equal(req.headers.authorization, 'Bearer ' + token);
      let source = ''; for await (const chunk of req) { source += chunk; assert.ok(source.length < 65536); }
      const body = JSON.parse(source), operation = req.url.split('/').at(-1);
      events.push({operation, state: body.state, sequence: body.sequence});
      if (operation === 'start') { execution = body.execution_id; started = Date.now(); }
      else if (operation === 'logs') {
        assert.equal(body.sequence, String(++sequence));
        assert.ok(!body.text.includes(token)); logs.push(body.text);
        if (body.text.includes('CI_DOCKER_READY')) cancelReady = true;
      } else if (operation === 'complete') conclusion = body.conclusion;
      else assert.ok(['heartbeat', 'steps'].includes(operation));
      // Lease validation requires a window of at most 60 seconds. Reading the
      // clock twice can produce 60001 ms when the second read crosses a tick.
      const now = Date.now();
      res.writeHead(200, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({version: 1, execution_id: execution, attempt_id: '1',
        state: conclusion ? 'completed' : 'running', server_time_ms: String(now),
        lease_until_ms: String(now + 60000), deadline_ms: String(started + 180000),
        cancel_requested: cancel && cancelReady, log_sequence: String(sequence), conclusion}));
    } catch (error) { failure = error; res.writeHead(500); res.end('fixture rejected request'); }
  });
  await new Promise(resolve => server.listen(0, '0.0.0.0', resolve));
  const script = [
    'test "$(id -u)" = 10001',
    'test "$(sudo -n id -u)" = 0',
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
  const assignment = {version: 1, attempt_id: '1', run_id: '1', job_id: '1', repository: 'test/ci',
    commit_sha: 'a'.repeat(40), lease_until_ms: String(Date.now() + 60000), server_time_ms: String(Date.now()), state: 'leased',
    job: {id: 'ci', name: 'CI profile', runs_on: ['self-hosted', 'linux'], contents_read: false, timeout_minutes: 3,
      steps: [{id: 'probe', name: 'Probe', run: script, shell: 'bash', working_directory: '.', env: {}, timeout_minutes: 0}]}};
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
    timer = setTimeout(() => { try { docker(['rm', '-f', name]); } catch {} }, 240000);
    const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
    if (failure) throw failure;
    assert.equal(code, cancel ? 1 : 0, diagnostic + '\n' + output + '\n' + JSON.stringify(events) + '\n' + logs.join(''));
    const report = JSON.parse(output.trim()); assert.equal(report.reported, true);
    assert.equal(report.conclusion, cancel ? 'cancelled' : 'success'); assert.equal(conclusion, report.conclusion);
    assert.ok(logs.join('').includes('CI_DOCKER_READY'));
    assert.equal(docker(['ps', '-aq', '--filter', 'name=^' + name + '$']).trim(), '');
    console.log('LINUX_CI_' + (cancel ? 'CANCELLATION' : 'EXECUTION') + '_OK');
  } finally {
    clearTimeout(timer); try { docker(['rm', '-f', name], {stdio: 'ignore'}); } catch {}
    docker(['volume', 'rm', name]);
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); fs.rmSync(root, {recursive: true, force: true});
  }
}
(async () => { await scenario(false); await scenario(true); })().catch(error => {console.error(error); process.exitCode = 1;});
