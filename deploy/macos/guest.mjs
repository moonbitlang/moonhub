import fs from 'node:fs/promises';
import { spawn, execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const root = '/var/lib/moonhub-guest';
const marker = '/Library/Application Support/MoonHub/guest.json';
const user = '_moonhub';
let phase = 'identity';
export function validatePayload(value) {
  assert.equal(value?.version, 1);
  assert.ok(typeof value.token === 'string' && /^[a-f0-9]{64}$/.test(value.token));
  const url = new URL(value.server);
  assert.ok(
    (url.protocol === 'https:' || (value.allow_http === true && url.protocol === 'http:')) &&
      !url.username &&
      !url.password &&
      url.pathname === '/' &&
      !url.search &&
      !url.hash,
  );
  assert.equal(url.origin, value.server);
  assert.ok(value.assignment?.job?.runs_on?.includes('macos'));
  assert.ok(!value.assignment.job.runs_on.some((os) => ['linux', 'windows'].includes(os)));
  assert.match(value.assignment.attempt_id, /^[1-9][0-9]*$/);
  return value;
}
async function identity() {
  assert.equal(process.platform, 'darwin');
  assert.equal(process.arch, 'arm64');
  assert.equal(process.getuid(), 0);
  assert.equal(
    execFileSync('/usr/sbin/sysctl', ['-n', 'kern.hv_vmm_present'], { encoding: 'utf8' }).trim(),
    '1',
  );
  const st = await fs.lstat(marker);
  assert.ok(st.isFile() && st.uid === 0 && !(st.mode & 0o022));
  const info = JSON.parse(await fs.readFile(marker, 'utf8'));
  assert.equal(info.version, 1);
  const uid = Number(execFileSync('/usr/bin/id', ['-u', user], { encoding: 'utf8' }).trim());
  const gid = Number(execFileSync('/usr/bin/id', ['-g', user], { encoding: 'utf8' }).trim());
  const groups = execFileSync('/usr/bin/id', ['-Gn', user], { encoding: 'utf8' })
    .trim()
    .split(/\s+/);
  assert.ok(uid > 0 && gid > 0 && !groups.includes('admin'));
  for (const name of [
    '/usr/local/bin/moonhub-runner',
    '/usr/local/bin/moonhub-runner-step',
    '/usr/local/lib/moonhub/bin/node',
  ]) {
    const file = await fs.stat(name);
    assert.ok(file.isFile() && file.uid === 0 && !(file.mode & 0o022));
  }
  return { uid, gid };
}
async function main() {
  const { uid, gid } = await identity();
  if (process.argv[2] === 'health') {
    execFileSync('/usr/local/bin/moonhub-runner', ['--help'], { stdio: 'ignore' });
    assert.deepEqual(await fs.readdir(root), []);
    console.log(
      JSON.stringify({ version: 1, os: 'macos', arch: 'arm64', clean: true, runtime: 1 }),
    );
    return;
  }
  assert.equal(process.argv[2], 'execute');
  phase = 'payload';
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk;
    assert.ok(Buffer.byteLength(input) <= 2097152 + 65536);
  }
  const payload = validatePayload(JSON.parse(input));
  // CreateNew makes this guest single-use, including failed/crashed executions.
  phase = 'workspace';
  const consumed = await fs.open(path.join(root, 'consumed'), 'wx', 0o600);
  await consumed.close();
  const workspace = path.join(root, 'workspace');
  await fs.mkdir(workspace, { mode: 0o700 });
  await fs.chown(workspace, uid, gid);
  const assignment = path.join(root, 'assignment.json');
  await fs.writeFile(assignment, JSON.stringify(payload.assignment), { flag: 'wx', mode: 0o644 });
  const args = [
    'execute',
    '--server',
    payload.server,
    '--assignment',
    assignment,
    '--workspace',
    workspace,
  ];
  if (payload.allow_http) args.push('--allow-http');
  phase = 'spawn';
  const child = spawn('/usr/local/bin/moonhub-runner', args, {
    uid,
    gid,
    env: { PATH: '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR: '/tmp', HOME: workspace },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let output = '',
    diagnostic = '';
  child.stdout.on('data', (b) => {
    output += b;
    if (Buffer.byteLength(output) > 65536) child.kill('SIGKILL');
  });
  child.stderr.on('data', (b) => {
    if (diagnostic.length < 8192) diagnostic += b;
  });
  const timeout = setTimeout(
    () => child.kill('SIGKILL'),
    (payload.assignment.job.timeout_minutes || 1) * 60000 + 15000,
  );
  child.stdin.on('error', () => {});
  child.stdin.end(payload.token + '\n');
  const code = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', resolve);
  });
  clearTimeout(timeout);
  // Protocol output only. Guest diagnostics can include private data.
  let report;
  try {
    report = JSON.parse(output);
  } catch {
    const reason = diagnostic.includes('isolated non-administrator')
      ? 'isolation'
      : diagnostic.includes('workspace must')
        ? 'workspace'
        : diagnostic.includes('launcher is not')
          ? 'launcher'
          : diagnostic.includes('invalid step plan')
            ? 'assignment'
            : 'runtime';
    console.log(JSON.stringify({ reported: false, error: reason }));
    process.exitCode = 2;
    return;
  }
  if (report.reported !== true) {
    console.log(JSON.stringify({ reported: false, error: 'runtime' }));
    process.exitCode = 2;
    return;
  }
  assert.ok(code === 0 || code === 1);
  console.log(JSON.stringify(report));
  process.exitCode = code;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  main().catch(() => {
    console.log(JSON.stringify({ reported: false, error: phase }));
    process.exitCode = 2;
  });
