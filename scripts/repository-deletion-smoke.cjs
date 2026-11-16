// Linux acceptance uses real Web/SSH processes and explicit pipe/FD barriers.
// All databases, credentials, hooks and Git data belong to this disposable fixture.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { createHash, randomBytes } = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');
const { DatabaseSync } = require('node:sqlite');

const root = path.resolve(__dirname, '..');
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/moonhub.exe');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-deletion-'));
const repos = path.join(temp, 'repos');
const gitDir = path.join(repos, 'root/demo.git');
const lockPath = path.join(repos, '.locks/repositories', createHash('sha256').update('root/demo').digest('hex') + '.lock');
const password = randomBytes(24).toString('hex');
const env = { ...process.env, DB_PATH: path.join(temp, 'moonhub.db'), MOONHUB_REPO_ROOT: repos,
  MOONHUB_HOOKS_PATH: path.join(temp, 'hooks'), MOONHUB_BIN: binary, MAIL_OUTBOX_DIR: path.join(temp, 'mail'),
  MOONHUB_DIFF_WORKER: process.env.MOONHUB_DIFF_WORKER || path.join(root, '_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe') };
const children = new Set();
let cookie = '', base;
const run = (command, args, options = {}) => execFileSync(command, args,
  { cwd: root, env, encoding: 'utf8', timeout: 30000, stdio: ['pipe', 'pipe', 'pipe'], ...options }).trim();
function child(command, args, extra = {}) {
  const process = spawn(command, args, { cwd: root, env: { ...env, ...extra }, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
  children.add(process);
  process.output = '';
  process.stdout.on('data', data => { process.output += data; });
  process.stderr.on('data', data => { process.output += data; });
  process.done = new Promise((resolve, reject) => {
    process.once('error', reject);
    process.once('close', code => { children.delete(process); resolve(code); });
  });
  return process;
}
async function until(check, message) {
  const deadline = Date.now() + 10000;
  do {
    if (await check()) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  } while (Date.now() < deadline);
  throw new Error(message);
}
function opened(pid, target) {
  try { return fs.readdirSync(`/proc/${pid}/fd`).some(fd => {
    try { return fs.readlinkSync(`/proc/${pid}/fd/${fd}`) === target; } catch { return false; }
  }); } catch { return false; }
}
function db(f) {
  const connection = new DatabaseSync(env.DB_PATH, { timeout: 5000 });
  try { return f(connection); } finally { connection.close(); }
}
async function request(route, fields) {
  const response = await fetch(base + route, { method: fields ? 'POST' : 'GET', redirect: 'manual',
    headers: cookie ? { Cookie: cookie } : {}, body: fields ? new URLSearchParams(fields) : undefined,
    signal: AbortSignal.timeout(20000) });
  if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
  return { status: response.status, body: await response.text() };
}
const repoId = () => db(c => c.prepare("SELECT r.id FROM repository r JOIN team t ON t.id=r.team_id WHERE t.name_key='root' AND r.name='demo'").get()?.id);
async function main() {
  assert.equal(process.platform, 'linux', 'FD barriers require Linux (the self-check runner)');
  fs.mkdirSync(repos);
  fs.mkdirSync(env.MOONHUB_HOOKS_PATH);
  fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  for (const hook of ['pre-receive', 'reference-transaction']) {
    fs.copyFileSync(path.join(root, 'deploy/hooks', hook), path.join(env.MOONHUB_HOOKS_PATH, hook));
    fs.chmodSync(path.join(env.MOONHUB_HOOKS_PATH, hook), 0o700);
  }
  const listener = net.createServer();
  await new Promise((resolve, reject) => { listener.once('error', reject); listener.listen(0, '127.0.0.1', resolve); });
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  base = `http://127.0.0.1:${port}`;
  const web = child(binary, [repos, '--assets', path.join(root, 'assets'), '--host', '127.0.0.1', '--port', String(port),
    '--root-user', 'root', '--root-password-file', path.join(temp, 'password')]);
  await until(async () => {
    assert.equal(web.exitCode, null, web.output);
    try { return (await fetch(base + '/-/login')).ok; } catch { return false; }
  }, 'Web startup');
  assert.equal((await request('/-/login', { name_key: 'root', password })).status, 303);
  assert.equal((await request('/-/change-password', { new_password: password, confirm_password: password })).status, 303);
  run(binary, ['repo-create', 'root/demo']);
  const originalId = repoId();
  run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', path.join(temp, 'key')]);
  const credential = run(binary, ['ssh-key-add', 'root'], { input: fs.readFileSync(path.join(temp, 'key.pub')) }).split('\t')[0];
  const gate = path.join(temp, 'gate');
  const ready = path.join(temp, 'ready');
  run('mkfifo', [gate]);
  const quote = s => "'" + s.replaceAll("'", "'\\''") + "'";
  const git = path.join(temp, 'git-barrier');
  // Entered only after SSH owns the repository lock. A FIFO releases it explicitly.
  fs.writeFileSync(git, `#!/bin/sh\nprintf ready > ${quote(ready)}\nread -r release < ${quote(gate)}\n`, { mode: 0o700 });
  const ssh = child(binary, ['ssh-serve', credential], { SSH_ORIGINAL_COMMAND: "git-receive-pack 'root/demo.git'", MOONHUB_GIT: git });
  ssh.stdin.end();
  await until(() => fs.existsSync(ready), 'SSH did not enter its locked Git operation');
  const inode = fs.statSync(lockPath).ino;
  assert.equal(fs.statSync(lockPath).mode & 0o777, 0o600);
  for (const directory of [path.join(repos, '.locks'), path.dirname(lockPath)]) assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
  const route = '/root/demo/settings/danger-zone/delete';
  const form = await request(route);
  assert.equal(form.status, 200);
  const csrf = form.body.match(/name="csrf_token" value="([^"]+)"/)[1];
  let completed = false;
  const deletion = request(route, { csrf_token: csrf, repository_id: String(originalId), confirmation: 'root/demo' }).then(result => { completed = true; return result; });
  await until(() => opened(web.pid, lockPath), 'Web did not wait on the same repository control file');
  assert.equal(completed, false, 'Web deleted during an SSH write');
  assert.equal(repoId(), originalId);
  fs.writeFileSync(gate, 'release\n');
  assert.equal(await ssh.done, 0, ssh.output);
  assert.equal((await deletion).status, 303);
  await until(() => db(c => c.prepare('SELECT count(*) n FROM repository_file_garbage').get().n) === 0, 'cleanup journal was not drained');
  assert.equal(fs.existsSync(gitDir), false);
  run(binary, ['repo-create', 'root/demo']);
  assert.notEqual(repoId(), originalId);
  assert.equal(fs.statSync(lockPath).ino, inode, 'cleanup replaced the control inode');

  // Hold the current control inode while SSH captures its identity and queues.
  // The fixture publishes a replacement inside that same critical section.
  const holder = child('python3', ['-u', '-c',
    'import fcntl,sys\nf=open(sys.argv[1],"r+")\nfcntl.flock(f,fcntl.LOCK_EX)\nprint("held",flush=True)\nsys.stdin.read(1)\n', lockPath]);
  await until(() => holder.output.includes('held'), 'control lock holder');
  fs.rmSync(ready);
  const stale = child(binary, ['ssh-serve', credential], { SSH_ORIGINAL_COMMAND: "git-receive-pack 'root/demo.git'", MOONHUB_GIT: git });
  stale.stdin.end();
  await until(() => opened(stale.pid, lockPath), 'old SSH request did not queue');
  db(c => {
    c.exec('BEGIN IMMEDIATE');
    c.prepare('DELETE FROM repository WHERE id=?').run(repoId());
    c.exec("INSERT INTO repository(team_id,name) SELECT id,'demo' FROM team WHERE name_key='root'; COMMIT");
  });
  fs.rmSync(gitDir, { recursive: true });
  run('git', ['init', '--bare', gitDir]);
  const bare = args => run('git', ['--git-dir=' + gitDir, ...args]);
  const blob = run('git', ['--git-dir=' + gitDir, 'hash-object', '-w', '--stdin'], { input: 'replacement\n' });
  const tree = run('git', ['--git-dir=' + gitDir, 'mktree'], { input: `100644 blob ${blob}\tkeep\n` });
  const commit = bare(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit-tree', tree, '-m', 'Replacement']);
  bare(['update-ref', 'refs/heads/main', commit]);
  fs.writeFileSync(path.join(gitDir, 'keep'), 'replacement');
  holder.stdin.end('x');
  assert.equal(await holder.done, 0, holder.output);
  assert.notEqual(await stale.done, 0, 'old SSH writer entered a rebuilt repository');
  assert.match(stale.output, /repository has changed/);
  assert.equal(fs.existsSync(ready), false, 'stale SSH request started Git');
  assert.equal(bare(['rev-parse', 'refs/heads/main']), commit);
  assert.equal(fs.readFileSync(path.join(gitDir, 'keep'), 'utf8'), 'replacement');
  assert.equal(fs.statSync(lockPath).ino, inode);
  console.log('REPOSITORY_DELETION_SMOKE_OK: Web/SSH exclusion, stable inode, cleanup, stale SSH rejection');
}
main().catch(error => { console.error(error); for (const process of children) console.error(process.output); process.exitCode = 1; }).finally(async () => {
  for (const process of children) { try { global.process.kill(-process.pid, 'SIGTERM'); } catch {} }
  await Promise.all([...children].map(process => process.done));
  fs.rmSync(temp, { recursive: true, force: true });
});
