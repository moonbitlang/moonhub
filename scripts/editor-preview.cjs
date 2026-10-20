// Local-only demo; account, database and Git repository are disposable.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { execFileSync, spawn } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const directory = path.join(root, '_build/editor-preview');
const stateFile = path.join(directory, 'preview.json');
const binary = path.join(root, '_build/native/debug/build/moonhub.exe');
const csrf = html => html.match(/name="csrf_token" value="([^"]+)"/)[1];
let started;

(async () => {
  if (fs.existsSync(stateFile)) {
    const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    if (process.argv.includes('--restart')) {
      process.kill(state.pid, 'SIGTERM');
      for (let i = 0; i < 50; i++) {
        try { process.kill(state.pid, 0); } catch { break; }
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      const log = fs.openSync(path.join(directory, 'server.log'), 'a', 0o600);
      const server = spawn(binary, [path.join(directory, 'repos'), '--assets', path.join(root, 'assets'), '--host', '127.0.0.1', '--port', new URL(state.base).port, '--root-user', state.username, '--root-password-file', path.join(directory, 'password')], { cwd: directory, env: { ...process.env, DB_PATH: path.join(directory, 'moonhub.db'), MAIL_OUTBOX_DIR: path.join(directory, 'mail') }, detached: true, stdio: ['ignore', log, log] });
      fs.closeSync(log); server.unref(); state.pid = server.pid;
      fs.writeFileSync(stateFile, JSON.stringify(state, null, 2), { mode: 0o600 });
      let ready = false;
      for (let i = 0; i < 150; i++) { try { if ((await fetch(state.base + '/-/login')).ok) { ready = true; break; } } catch {} await new Promise(resolve => setTimeout(resolve, 100)); }
      assert.ok(ready, 'restarted preview did not become healthy');
    }
    try { process.kill(state.pid, 0); console.log(JSON.stringify({ base: state.base, mr: state.mr, issue: state.issue, username: state.username, credentials: stateFile })); return; } catch { throw new Error('Previous preview stopped; preserve or rename _build/editor-preview before starting a fresh instance.'); }
  }
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  fs.mkdirSync(path.join(directory, 'repos'), { recursive: true });
  fs.cpSync(path.join(root, 'db'), path.join(directory, 'db'), { recursive: true });
  const password = randomBytes(15).toString('base64url');
  const passwordFile = path.join(directory, 'password');
  fs.writeFileSync(passwordFile, password, { mode: 0o600 });
  const listener = net.createServer(); await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  const port = listener.address().port; await new Promise(resolve => listener.close(resolve));
  const base = 'http://127.0.0.1:' + port;
  const env = { ...process.env, DB_PATH: path.join(directory, 'moonhub.db'), MAIL_OUTBOX_DIR: path.join(directory, 'mail') };
  const log = fs.openSync(path.join(directory, 'server.log'), 'a', 0o600);
  const server = spawn(binary, [path.join(directory, 'repos'), '--assets', path.join(root, 'assets'), '--host', '127.0.0.1', '--port', String(port), '--root-user', 'preview', '--root-password-file', passwordFile], { cwd: directory, env, detached: true, stdio: ['ignore', log, log] });
  started = server;
  fs.closeSync(log); server.unref();
  let ready = false;
  for (let i = 0; i < 150; i++) { try { if ((await fetch(base + '/-/login')).ok) { ready = true; break; } } catch {} await new Promise(resolve => setTimeout(resolve, 100)); }
  assert.ok(ready, 'preview server did not start');
  let cookie;
  async function form(route, fields, status = 303) {
    const response = await fetch(base + route, { method: 'POST', redirect: 'manual', headers: cookie ? { Cookie: cookie } : {}, body: new URLSearchParams(fields) });
    if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
    const html = await response.text(); assert.equal(response.status, status, html); return response;
  }
  const html = async route => (await fetch(base + route, { headers: { Cookie: cookie } })).text();
  await form('/-/login', { name_key: 'preview', password });
  await form('/-/change-password', { new_password: password, confirm_password: password });
  execFileSync(binary, ['repo-create', 'preview/editor-demo'], { cwd: directory, env, stdio: 'pipe' });
  const git = (args, input) => execFileSync('git', ['--git-dir=' + path.join(directory, 'repos/preview/editor-demo.git'), '-c', 'user.name=Preview', '-c', 'user.email=preview@example.invalid', ...args], { input, encoding: 'utf8' }).trim();
  const blob = text => git(['hash-object', '-w', '--stdin'], text);
  const tree = text => git(['mktree'], '100644 blob ' + blob(text) + '\tREADME.md\n');
  const initial = git(['commit-tree', tree('# Editor preview\n\nOriginal text.\n'), '-m', 'Initial demo']);
  git(['update-ref', 'refs/heads/master', initial]);
  const changed = git(['commit-tree', tree('# Editor preview\n\nReview the new Markdown editor.\n\nTry a line comment here.\n'), '-p', initial, '-m', 'Try EasyMDE editing']);
  git(['update-ref', 'refs/heads/editor-demo', changed]);
  const repository = '/preview/editor-demo';
  const description = '# Try the Markdown editor\n\nSelect some text and try **bold**, links, quotes or code.\n\n- Paste or drop a screenshot\n- Switch between Write and Preview\n- Undo and redo a change\n\n> Descriptions, comments and replies use the same editor.\n';
  await form(repository + '/merge-requests', { csrf_token: csrf(await html(repository + '/merge-requests/new')), title: 'Preview EasyMDE in descriptions and code reviews', description, source: 'editor-demo', target: 'master' });
  const mr = repository + '/merge-requests/1';
  await form(mr + '/review', { csrf_token: csrf(await html(mr)), version: '1', decision: 'comment', body: 'Try replying to this discussion. You can also open **Changes** and add a line comment.' });
  await form(repository + '/issues', { csrf_token: csrf(await html(repository + '/issues/new')), title: 'Try the source editor and image uploads', description, assignee: '0' });
  const state = { base, mr, issue: repository + '/issues/1', newIssue: repository + '/issues/new', pid: server.pid, directory, username: 'preview', password, cookie };
  fs.writeFileSync(stateFile, JSON.stringify(state, null, 2), { mode: 0o600 });
  console.log(JSON.stringify({ base, mr, issue: state.issue, username: state.username, credentials: stateFile }));
})().catch(error => { started?.kill('SIGTERM'); console.error(error); process.exitCode = 1; });
