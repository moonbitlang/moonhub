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
  process.stdoutText = '';
  process.stderrText = '';
  process.stdout.on('data', data => { process.output += data; process.stdoutText += data; });
  process.stderr.on('data', data => { process.output += data; process.stderrText += data; });
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
  for (const service of ['git-receive-pack', 'git-upload-pack']) {
    const holder = child('python3', ['-u', '-c',
      'import fcntl,sys\nf=open(sys.argv[1],"r+")\nfcntl.flock(f,fcntl.LOCK_EX)\nprint("held",flush=True)\nsys.stdin.read(1)\n', lockPath]);
    await until(() => holder.output.includes('held'), 'control lock holder');
    fs.rmSync(ready, { force: true });
    const stale = child(binary, ['ssh-serve', credential], { SSH_ORIGINAL_COMMAND: `${service} 'root/demo.git'`, MOONHUB_GIT: git });
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
    await until(() => stale.exitCode !== null || fs.existsSync(ready), 'stale SSH request did not finish');
    assert.equal(fs.existsSync(ready), false, 'stale SSH request started Git');
    assert.notEqual(await stale.done, 0, `old SSH ${service} entered a rebuilt repository`);
    assert.match(stale.output, /repository has changed/);
    assert.equal(bare(['rev-parse', 'refs/heads/main']), commit);
    assert.equal(fs.readFileSync(path.join(gitDir, 'keep'), 'utf8'), 'replacement');
    assert.equal(fs.statSync(lockPath).ino, inode);
  }

  // Admitted readers retain only the immutable ID's lifetime lock.
  db(c => {
    c.exec(`INSERT INTO "user"(name_key,display_name,password_hash,is_site_admin) VALUES('reader','Reader','fixture',0)`);
    c.prepare("UPDATE repository SET visibility='public' WHERE id=?").run(repoId());
  });
  run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', path.join(temp, 'reader-key')]);
  const readerCredential = run(binary, ['ssh-key-add', 'reader'], { input: fs.readFileSync(path.join(temp, 'reader-key.pub')) }).split('\t')[0];
  const readId = repoId();
  const readerPath = id => path.join(repos, '.locks/repository-readers', `${id}.lock`);
  const canLock = (target, shared = false) => run('python3', ['-c',
    'import fcntl,sys\nf=open(sys.argv[1],"r+")\ntry:\n fcntl.flock(f,(fcntl.LOCK_SH if sys.argv[2]=="shared" else fcntl.LOCK_EX)|fcntl.LOCK_NB)\n print("free")\nexcept BlockingIOError:\n print("busy")\n',
    target, shared ? 'shared' : 'exclusive']) === 'free';
  const alive = pid => { try { global.process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
  const csrfFor = async route => {
    const form = await request(route);
    assert.equal(form.status, 200, form.body);
    return form.body.match(/name="csrf_token" value="([^"]+)"/)[1];
  };
  const journal = id => db(c => c.prepare("SELECT * FROM repository_file_garbage WHERE repository_id=? AND kind='git'").get(id));
  async function gatedRead(label, { key = readerCredential, options = [], extra = {} } = {}) {
    const readGate = path.join(temp, `${label}-gate`);
    const readReady = path.join(temp, `${label}-ready`);
    const terminated = path.join(temp, `${label}-terminated`);
    const readGit = path.join(temp, `${label}-git`);
    run('mkfifo', [readGate]);
    // This stand-in records SIGTERM but remains alive until released or SIGKILL.
    // Its FIFO and PID are barriers; no timing assumption establishes lock safety.
    fs.writeFileSync(readGit, `#!/usr/bin/python3
import os,signal,sys
terminated=${JSON.stringify(terminated)}
def term(signum, frame):
 with open(terminated,'w') as f: f.write('terminated')
signal.signal(signal.SIGTERM,term)
fd=os.open(${JSON.stringify(readGate)},os.O_RDWR)
with open(${JSON.stringify(readReady)},'w') as f: f.write(str(os.getpid()))
os.read(fd,1)
os.close(fd)
if os.path.exists(terminated): sys.exit(0)
os.execv('/usr/bin/git',['git']+sys.argv[1:])
`, { mode: 0o700 });
    const process = child(binary, ['ssh-serve', key, ...options], {
      SSH_ORIGINAL_COMMAND: "git-upload-pack 'root/demo.git'", MOONHUB_GIT: readGit, ...extra,
    });
    process.stdin.end('0000');
    await until(() => {
      assert.equal(process.exitCode, null, process.output);
      return fs.existsSync(readReady) && fs.readFileSync(readReady, 'utf8').length > 0 && !opened(process.pid, lockPath);
    }, 'SSH read did not finish admission');
    return { process, readGate, terminated, pid: Number(fs.readFileSync(readReady, 'utf8')) };
  }
  const readers = [await gatedRead('parallel-0'), await gatedRead('parallel-1')];
  assert.equal(canLock(lockPath), true, 'admitted reads kept the name write lock busy');
  assert.equal(canLock(readerPath(readId)), false, 'cleanup passed live readers');
  const readerInode = fs.statSync(readerPath(readId)).ino;
  assert.equal(fs.statSync(readerPath(readId)).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(readerPath(readId))).mode & 0o777, 0o700);

  // Real receive-pack, hooks, secret persistence and visibility changes all finish
  // before either stalled read is released.
  const transport = path.join(temp, 'transport');
  fs.writeFileSync(transport, `#!/bin/sh\nfor arg do SSH_ORIGINAL_COMMAND=$arg; done\nexport SSH_ORIGINAL_COMMAND\nexec ${quote(binary)} ssh-serve ${quote(credential)}\n`, { mode: 0o700 });
  const source = path.join(temp, 'source');
  run('git', ['clone', '--no-hardlinks', '--branch', 'main', gitDir, source]);
  fs.writeFileSync(path.join(source, 'pushed'), 'during read\n');
  run('git', ['-C', source, 'add', 'pushed']);
  run('git', ['-C', source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'Push during read']);
  run('git', ['-C', source, 'push', 'test-host:root/demo.git', 'main'], {
    env: { ...env, GIT_SSH: transport, GIT_SSH_VARIANT: 'ssh', MOONHUB_GIT: '/usr/bin/git' },
  });
  const publicCommit = run('git', ['-C', source, 'rev-parse', 'HEAD']);
  assert.equal(run('git', ['--git-dir=' + gitDir, 'rev-parse', 'refs/heads/main']), publicCommit);
  const secretRoute = '/root/demo/settings/secrets';
  assert.equal((await request(secretRoute, { csrf_token: await csrfFor(secretRoute + '/new'),
    name: 'READ_TEST', value: 'fixture-secret', branch: 'main', workflow: '.github/workflows/test.yml', version: '0' })).status, 303);
  assert.equal(db(c => c.prepare("SELECT count(*) n FROM repository_secret WHERE repository_id=? AND name='READ_TEST'").get(readId).n), 1);
  const visibilityRoute = '/root/demo/settings/danger-zone/visibility';
  assert.equal((await request(visibilityRoute, { csrf_token: await csrfFor(visibilityRoute),
    repository_id: String(readId), previous: 'public', visibility: 'private' })).status, 303);
  const newlyDenied = child(binary, ['ssh-serve', readerCredential], { SSH_ORIGINAL_COMMAND: "git-upload-pack 'root/demo.git'" });
  newlyDenied.stdin.end('0000');
  assert.notEqual(await newlyDenied.done, 0, 'new read bypassed private visibility');
  assert.equal(newlyDenied.stdoutText, '', 'denied read advertised refs');
  const publicRefs = run('git', ['--git-dir=' + gitDir, 'show-ref']).split('\n').sort();
  for (const [index, reader] of readers.entries()) {
    assert.equal(reader.process.exitCode, null, 'existing read was cancelled by privatization');
    fs.writeFileSync(reader.readGate, 'x');
    assert.equal(await reader.process.done, 0, reader.process.output);
    const advertised = [...reader.process.stdoutText.matchAll(/([0-9a-f]{40}) (refs\/heads\/[^\0\n]+)/g)]
      .map(match => `${match[1]} ${match[2]}`).sort();
    assert.deepEqual(advertised, publicRefs, 'old read advertised refs outside its repository');
    assert.equal(canLock(readerPath(readId)), index === readers.length - 1, 'cleanup passed a remaining reader');
  }

  // Logical deletion completes while Git is alive; cleanup must wait for reap.
  const deletedReaders = [await gatedRead('deleted-0', { key: credential }), await gatedRead('deleted-1', { key: credential })];
  assert.equal((await request(route, { csrf_token: await csrfFor(route), repository_id: String(readId), confirmation: 'root/demo' })).status, 303);
  assert.equal(repoId(), undefined);
  for (const reader of deletedReaders) {
    await until(() => fs.existsSync(reader.terminated), 'deletion did not signal the original reader');
    assert.equal(alive(reader.pid), true, 'Git exited before the cancellation barrier');
  }
  assert.ok(journal(readId));
  assert.equal(journal(readId).attempts, 0, 'lock contention incremented failures');
  assert.equal(fs.existsSync(path.join(gitDir, 'HEAD')), true);
  assert.throws(() => run(binary, ['repo-create', 'root/demo']), /still being deleted/);
  fs.writeFileSync(deletedReaders[0].readGate, 'x');
  assert.notEqual(await deletedReaders[0].process.done, 0, 'deleted reader reported success');
  assert.equal(alive(deletedReaders[0].pid), false, 'reader lock released before process reap');
  assert.equal(alive(deletedReaders[1].pid), true);
  assert.equal(canLock(readerPath(readId)), false);
  assert.ok(journal(readId));
  assert.equal(fs.existsSync(path.join(gitDir, 'HEAD')), true);
  // The remaining reader ignores TERM: runtime must force-kill it after 5000ms.
  await until(() => deletedReaders[1].process.exitCode !== null, 'reader ignoring termination was not force-killed');
  assert.notEqual(await deletedReaders[1].process.done, 0);
  assert.equal(alive(deletedReaders[1].pid), false);
  assert.equal(canLock(readerPath(readId)), true);
  await until(() => !journal(readId), 'read cleanup journal was not drained');
  assert.equal(fs.existsSync(gitDir), false);
  assert.equal(fs.statSync(readerPath(readId)).ino, readerInode, 'cleanup replaced reader control inode');
  run(binary, ['repo-create', 'root/demo']);
  assert.notEqual(repoId(), readId);
  assert.equal(db(c => c.prepare('SELECT visibility FROM repository WHERE id=?').get(repoId()).visibility), 'private');
  const replacementBlob = run('git', ['--git-dir=' + gitDir, 'hash-object', '-w', '--stdin'], { input: 'private replacement\n' });
  const replacementTree = run('git', ['--git-dir=' + gitDir, 'mktree'], { input: `100644 blob ${replacementBlob}\tprivate\n` });
  const replacementCommit = run('git', ['--git-dir=' + gitDir, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit-tree', replacementTree, '-m', 'Private replacement']);
  run('git', ['--git-dir=' + gitDir, 'update-ref', 'refs/heads/private-replacement', replacementCommit]);
  for (const { process } of [...readers, ...deletedReaders]) {
    assert.doesNotMatch(process.stdoutText, /refs\/heads\/private-replacement/);
    assert.equal(process.stdoutText.includes(replacementCommit), false);
  }
  const denied = child(binary, ['ssh-serve', readerCredential], { SSH_ORIGINAL_COMMAND: "git-upload-pack 'root/demo.git'" });
  denied.stdin.end('0000');
  assert.notEqual(await denied.done, 0, 'ordinary reader entered private replacement');
  assert.equal(denied.stdoutText, '');
  assert.equal(fs.statSync(lockPath).ino, inode, 'read lifecycle replaced the name control inode');

  for (const reason of ['external', 'identity', 'validation', 'maximum']) {
    const currentId = repoId();
    const reader = await gatedRead(reason, { key: credential,
      options: reason === 'maximum' ? ['--read-max-seconds', '1'] : [] });
    if (reason === 'external') reader.process.kill('SIGTERM');
    if (reason === 'identity') db(c => c.prepare("UPDATE repository SET name='renamed' WHERE id=?").run(currentId));
    if (reason === 'validation') db(c => c.exec('ALTER TABLE repository RENAME TO unavailable_repository'));
    await until(() => fs.existsSync(reader.terminated), `${reason} did not terminate Git`);
    assert.equal(alive(reader.pid), true);
    assert.equal(canLock(readerPath(currentId)), false, `${reason} released before Git exited`);
    fs.writeFileSync(reader.readGate, 'x');
    assert.notEqual(await reader.process.done, 0, `${reason} read reported success`);
    assert.equal(alive(reader.pid), false);
    assert.equal(canLock(readerPath(currentId)), true);
    assert.equal(canLock(lockPath), true);
    assert.equal(reader.process.stdoutText, '', 'diagnostic contaminated Git stdout');
    if (reason === 'identity') db(c => c.prepare("UPDATE repository SET name='demo' WHERE id=?").run(currentId));
    if (reason === 'validation') {
      db(c => c.exec('ALTER TABLE unavailable_repository RENAME TO repository'));
      assert.doesNotMatch(reader.process.stderrText, /SELECT|unavailable_repository|no such table/);
    }
    if (reason === 'maximum') assert.match(reader.process.stderrText, /maximum duration/);
  }
  const failed = child(binary, ['ssh-serve', credential], { SSH_ORIGINAL_COMMAND: "git-upload-pack 'root/demo.git'", MOONHUB_GIT: path.join(temp, 'missing-git') });
  failed.stdin.end('0000');
  assert.notEqual(await failed.done, 0, 'missing Git succeeded');
  assert.equal(failed.stdoutText, '');
  assert.doesNotMatch(failed.stderrText, /missing-git/);
  assert.equal(canLock(readerPath(repoId())), true);
  assert.equal(canLock(lockPath), true);
  // Real upload-pack's idle timeout, with stdin deliberately held open.
  const idle = child(binary, ['ssh-serve', credential, '--read-idle-timeout-seconds', '1', '--read-max-seconds', '10'],
    { SSH_ORIGINAL_COMMAND: "git-upload-pack 'root/demo.git'", MOONHUB_GIT: '/usr/bin/git' });
  await until(() => idle.stdoutText.includes('refs/heads/private-replacement'), 'idle read did not advertise refs');
  await until(() => idle.exitCode !== null, 'upload-pack idle timeout did not fire');
  assert.notEqual(await idle.done, 0);
  assert.doesNotMatch(idle.stderrText, /maximum duration/);
  assert.equal(canLock(readerPath(repoId())), true);
  assert.equal(canLock(lockPath), true);
  console.log('REPOSITORY_DELETION_SMOKE_OK: admission and reader lifetimes, real push, secrets, visibility, deletion cancellation, forced reap, deadlines, stale identity and private ref isolation');
}
main().catch(error => { console.error(error); for (const process of children) console.error(process.output); process.exitCode = 1; }).finally(async () => {
  for (const process of children) { try { global.process.kill(-process.pid, 'SIGTERM'); } catch {} }
  await Promise.all([...children].map(process => process.done));
  fs.rmSync(temp, { recursive: true, force: true });
});
