const assert = require('node:assert/strict');
const { spawn, execFileSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const image = process.env.MOONHUB_RUNNER_IMAGE || 'moonhub:runner-step3';

async function scenario(cancel) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-runner-smoke-'));
  const name = `moonhub-runner-smoke-${crypto.randomBytes(6).toString('hex')}`;
  const token = crypto.randomBytes(32).toString('hex');
  const log = [];
  const steps = [];
  let execution = '';
  let sequence = 0n;
  let started = 0;
  let cancelled = false;
  let complete = '';
  let soleProcess = false;
  let failure;
  const server = http.createServer(async (req, res) => {
    try {
      assert.equal(req.headers.authorization, `Bearer ${token}`);
      let text = '';
      for await (const chunk of req) { text += chunk; assert.ok(text.length < 65536); }
      const body = JSON.parse(text);
      const operation = req.url.split('/').pop();
      const now = Date.now();
      if (operation === 'start') { execution = body.execution_id; started = now; assert.match(execution, /^[a-f0-9]{32}$/); }
      if (operation === 'logs') {
        const next = BigInt(body.sequence);
        assert.equal(next, sequence + 1n);
        sequence = next;
        assert.ok(!body.text.includes(token));
        assert.ok(!body.text.includes('controller-only-sentinel'));
        log.push(body.text);
      }
      if (operation === 'steps') steps.push(body);
      if (operation === 'heartbeat' && cancel) cancelled = true;
      if (operation === 'complete') {
        assert.equal(BigInt(body.last_log_sequence), sequence);
        complete = body.conclusion;
        const processes = execFileSync('docker', ['top', name, '-eo', 'pid,comm'], { encoding: 'utf8' }).trim().split('\n').slice(1);
        soleProcess = processes.length === 1 && /^\s*\d+\s+moonhub\s*$/.test(processes[0]);
      }
      res.writeHead(200, { 'Content-Type': 'application/json', Connection: 'close' });
      res.end(JSON.stringify({
        version: 1, execution_id: execution, attempt_id: '1',
        state: complete ? 'completed' : 'running', lease_until_ms: String(now + 60000),
        server_time_ms: String(now), deadline_ms: String(started + 60000),
        cancel_requested: cancelled, log_sequence: String(sequence), conclusion: complete,
      }));
    } catch (error) {
      failure = error;
      res.writeHead(500); res.end('mock server rejected request');
    }
  });
  await new Promise(resolve => server.listen(0, '0.0.0.0', resolve));
  const port = server.address().port;
  const probe = [
    'test "$(id -u)" = 10001',
    'test "$PPID" = 1',
    'test -z "${MOONHUB_PROVIDER_TOKEN:-}"',
    'test ! -e /var/run/docker.sock',
    'test ! -e /data/moonhub.db',
    'if cat /proc/1/environ >/dev/null 2>&1; then exit 91; fi',
    'setsid sh -c "sleep 30" >/dev/null 2>&1 &',
    'printf "container-ready\\n"',
    ...(cancel ? ['sleep 30'] : []),
  ].join('\n');
  const build = [
    'mkdir probe; cd probe',
    'printf \'name = "test/runner_probe"\\npreferred_target = "native"\\n\' > moon.mod',
    'printf \'pkgtype(kind: "executable")\\n\' > moon.pkg',
    'printf \'fn main { println("native-ok") }\\n\' > main.mbt',
    'moon run --strip -j 1 .',
  ].join('\n');
  const assignment = {
    version: 1, attempt_id: '1', run_id: '1', job_id: '1', repository: 'test/probe',
    commit_sha: 'a'.repeat(40), lease_until_ms: String(Date.now() + 60000), server_time_ms: String(Date.now()), state: 'leased',
    job: { id: 'build', name: 'Build', runs_on: ['self-hosted', 'linux'], timeout_minutes: 1,
      steps: [probe, ...(cancel ? [] : [build])].map((run, i) => ({ id: `step_${i}`, name: `Step ${i}`, run, shell: 'bash', working_directory: '.', env: {}, timeout_minutes: 0 })),
    },
  };
  const manifest = path.join(root, 'assignment.json');
  fs.writeFileSync(manifest, JSON.stringify(assignment), { mode: 0o644 });
  let timer;
  try {
    const args = ['run', '--rm', '--name', name, '--read-only', '--cap-drop=ALL', '--security-opt', 'no-new-privileges',
      '--pids-limit=64', '--memory=512m', '--cpus=1',
      '--tmpfs', '/tmp:rw,noexec,nosuid,nodev,size=64m', '--tmpfs', '/workspace:rw,exec,nosuid,nodev,size=128m,uid=10001,gid=10001,mode=0700',
      '--mount', `type=bind,src=${manifest},dst=/control/assignment.json,readonly`,
      '--add-host', 'host.docker.internal:host-gateway', '-e', 'MOONHUB_PROVIDER_TOKEN=controller-only-sentinel', '-i', image,
      '--server', `http://host.docker.internal:${port}`, '--assignment', '/control/assignment.json', '--allow-http'];
    const child = spawn('docker', args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = ''; let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.stdin.on('error', () => {});
    child.stdin.end(`${token}\n`);
    timer = setTimeout(() => { try { execFileSync('docker', ['rm', '-f', name], { stdio: 'ignore' }); } catch {} }, 90000);
    const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
    clearTimeout(timer);
    if (failure) throw failure;
    assert.equal(code, cancel ? 1 : 0, `${stderr}\n${stdout}\n${log.join('')}`);
    const report = JSON.parse(stdout.trim());
    assert.equal(report.reported, true);
    assert.equal(report.conclusion, cancel ? 'cancelled' : 'success');
    assert.equal(complete, report.conclusion);
    assert.ok(soleProcess, 'job descendants remained alive at completion');
    assert.ok(log.join('').includes('container-ready'));
    if (!cancel) assert.ok(log.join('').includes('native-ok'));
    console.log(`${cancel ? 'Cancellation' : 'Execution'} smoke passed: non-root PID 1, private credentials, no daemon socket, descendants reaped.`);
  } finally {
    clearTimeout(timer);
    try { execFileSync('docker', ['rm', '-f', name], { stdio: 'ignore' }); } catch {}
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  }
}

(async () => { await scenario(false); await scenario(true); })().catch(error => { console.error(error); process.exitCode = 1; });
