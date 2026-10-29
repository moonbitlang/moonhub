// Disposable local repositories and mock SSH only; no external Git destination is contacted.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { randomBytes } = require('node:crypto');
const { execFileSync, spawn } = require('node:child_process');
const { once } = require('node:events');
const { DatabaseSync } = require('node:sqlite');
const root = path.resolve(__dirname, '..');
const { chromium } = require(path.join(root, 'js/node_modules/playwright'));
const review = path.join(root, '.impeccable/review/mirrors');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-mirrors-'));
const binary = path.join(root, '_build/native/debug/build/moonhub.exe');
const database = path.join(temp, 'moonhub.db');
const password = randomBytes(24).toString('hex');
let server, browser;
const env = { ...process.env, DB_PATH: database, MAIL_OUTBOX_DIR: path.join(temp, 'mail'),
  MOONHUB_SSH_IMPORT_ROOT: path.join(temp, 'credentials'), MOONHUB_IMPORT_SSH: path.join(temp, 'outbound-ssh') };
function sql(statement, ...params) {
  const db = new DatabaseSync(database, { timeout: 5000 });
  try { return db.prepare(statement).all(...params); } finally { db.close(); }
}
async function until(check, message) {
  for (let i = 0; i < 200; i++) { if (await check()) return; await new Promise(r => setTimeout(r, 100)); }
  throw new Error(message);
}
(async () => {
  fs.mkdirSync(review, { recursive: true });
  fs.mkdirSync(path.join(temp, 'repos'));
  fs.mkdirSync(path.join(temp, 'credentials/root'), { recursive: true });
  fs.cpSync(path.join(root, 'db'), path.join(temp, 'db'), { recursive: true });
  fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  for (const [name, value] of Object.entries({ known_hosts: 'local test host key', allowed_hosts: 'github.com:22\n' })) {
    fs.writeFileSync(path.join(temp, 'credentials/root', name), value, { mode: 0o600 });
  }
  const remote = path.join(temp, 'github.git');
  execFileSync('git', ['init', '--bare', remote], { stdio: 'pipe' });
  const authorized = path.join(temp, 'authorized-public-key');
  fs.writeFileSync(env.MOONHUB_IMPORT_SSH, '#!/bin/sh\nset -eu\nactual=$(/usr/bin/ssh-keygen -y -f "$MOONHUB_IMPORT_IDENTITY" | cut -d " " -f 1-2)\ntest "$actual" = "$(cat "' + authorized + '")"\nexec git receive-pack "' + remote + '"\n', { mode: 0o700 });
  const listener = http.createServer(); listener.listen(0, '127.0.0.1'); await once(listener, 'listening');
  const port = listener.address().port; await new Promise(r => listener.close(r));
  const base = 'http://127.0.0.1:' + port;
  const log = fs.openSync(path.join(temp, 'server.log'), 'w', 0o600);
  server = spawn(binary, [path.join(temp, 'repos'), '--assets', path.join(root, 'assets'), '--host', '127.0.0.1', '--port', String(port), '--root-user', 'root', '--root-password-file', path.join(temp, 'password')], { cwd: temp, env, stdio: ['ignore', log, log] });
  fs.closeSync(log);
  await until(async () => { if (server.exitCode !== null) throw new Error(fs.readFileSync(path.join(temp, 'server.log'), 'utf8')); try { return (await fetch(base + '/-/login')).ok; } catch { return false; } }, 'server did not start');
  let cookie;
  async function form(route, fields, expected = 303) {
    const r = await fetch(base + route, { method: 'POST', body: new URLSearchParams(fields), headers: cookie ? { Cookie: cookie } : {}, redirect: 'manual' });
    if (r.headers.get('set-cookie')) cookie = r.headers.get('set-cookie').split(';')[0];
    const body = await r.text(); assert.equal(r.status, expected, body); return r;
  }
  const html = async route => (await fetch(base + route, { headers: { Cookie: cookie } })).text();
  const csrf = text => text.match(/name="csrf_token" value="([^"]+)"/)[1];
  await form('/-/login', { name_key: 'root', password });
  await form('/-/change-password', { new_password: password, confirm_password: password });
  execFileSync(binary, ['repo-create', 'root/demo'], { cwd: temp, env, stdio: 'pipe' });
  const dir = path.join(temp, 'repos/root/demo.git');
  const git = (gitDir, args, input) => execFileSync('git', ['--git-dir=' + gitDir, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', ...args], { input, encoding: 'utf8' }).trim();
  const tree = git(dir, ['mktree'], '');
  const initial = git(dir, ['commit-tree', tree, '-m', 'Initial commit']);
  git(dir, ['update-ref', 'refs/heads/main', initial]);
  git(dir, ['tag', '-a', 'v1', '-m', 'Release', initial]);
  git(dir, ['update-ref', 'refs/moonhub/private', initial]);
  const route = '/root/demo/settings/mirrors';
  const newForm = await html(route + '/new');
  assert.ok(!newForm.includes('name="active" value="1" checked'));
  await form(route, { csrf_token: csrf(newForm), url: 'git@github.com:moonhub-preview/demo.git' });
  const mirror = () => sql('SELECT * FROM repository_mirror')[0];
  const keyPair = () => sql('SELECT private_key,public_key FROM mirror_ssh_key WHERE mirror_id=?', mirror().id)[0];
  const edit = route + '/' + mirror().id;
  assert.equal(mirror().status, 'disabled');
  assert.ok((await html(edit)).includes(keyPair().public_key));
  assert.ok(!(await html(edit)).includes(keyPair().private_key));
  fs.writeFileSync(authorized, keyPair().public_key.split(' ').slice(0, 2).join(' '), { mode: 0o600 });
  await form(edit, { csrf_token: csrf(await html(edit)), version: String(mirror().version), url: mirror().url, active: '1' });
  await until(() => mirror().status === 'succeeded', 'initial sync failed');
  assert.equal(git(remote, ['rev-parse', 'refs/heads/main']), initial);
  assert.equal(git(remote, ['rev-parse', 'refs/tags/v1']), git(dir, ['rev-parse', 'refs/tags/v1']));
  assert.equal(git(remote, ['for-each-ref', 'refs/moonhub/']), '');
  assert.equal(sql('SELECT COUNT(*) AS count FROM webhook_event')[0].count, 0);
  // Real receive-pack and trusted reference-transaction hooks, with local SSH transport.
  const hooks = path.join(temp, 'hooks'); fs.mkdirSync(hooks);
  for (const name of ['pre-receive', 'reference-transaction']) {
    fs.copyFileSync(path.join(root, 'deploy/hooks', name), path.join(hooks, name)); fs.chmodSync(path.join(hooks, name), 0o700);
  }
  const key = execFileSync(binary, ['ssh-key-add', 'root'], { cwd: temp, env, input: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB\n', encoding: 'utf8' }).trim().split('\t')[0];
  const transport = path.join(temp, 'incoming-ssh');
  fs.writeFileSync(transport, '#!/bin/sh\nfor arg do SSH_ORIGINAL_COMMAND=$arg; done\nexport SSH_ORIGINAL_COMMAND\nexec "$MOONHUB_BIN" ssh-serve "$MOONHUB_TEST_KEY_ID"\n', { mode: 0o700 });
  const source = path.join(temp, 'source'); fs.mkdirSync(source);
  const pushEnv = { ...env, MOONHUB_REPO_ROOT: path.join(temp, 'repos'), MOONHUB_BIN: binary, MOONHUB_HOOKS_PATH: hooks, MOONHUB_TEST_KEY_ID: key, GIT_SSH: transport, GIT_SSH_VARIANT: 'simple' };
  const sourceGit = args => execFileSync('git', args, { cwd: source, env: pushEnv, encoding: 'utf8', timeout: 30000, stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  sourceGit(['init', '-q', '-b', 'topic']); sourceGit(['config', 'user.name', 'Mirror fixture']); sourceGit(['config', 'user.email', 'fixture@example.invalid']);
  sourceGit(['commit', '--allow-empty', '-qm', 'Receive-pack fixture']);
  sourceGit(['push', 'fixture:/root/demo.git', 'HEAD:refs/heads/topic', 'HEAD:refs/tags/received']);
  const head = sourceGit(['rev-parse', 'HEAD']);
  await until(() => mirror().status === 'succeeded' && git(remote, ['for-each-ref', '--format=%(objectname)', 'refs/heads/topic']) === head, 'incoming push not mirrored');
  // Turn on pruning and verify actual branch/tag deletion.
  await form(edit, { csrf_token: csrf(await html(edit)), version: String(mirror().version), url: mirror().url, active: '1', prune: '1' });
  await until(() => mirror().status === 'succeeded', 'edited mirror not synced');
  sourceGit(['push', 'fixture:/root/demo.git', ':refs/heads/topic', ':refs/tags/received']);
  await until(() => mirror().status === 'succeeded' && !git(remote, ['for-each-ref', '--format=%(refname)']).includes('topic'), 'deleted refs not pruned');
  assert.ok(!git(remote, ['for-each-ref', '--format=%(refname)']).includes('received'));
  // MR merge is another real source trigger, independent of CI/webhooks.
  const changed = git(dir, ['commit-tree', tree, '-p', initial, '-m', 'Merge fixture']);
  git(dir, ['update-ref', 'refs/heads/feature', changed]);
  await form('/root/demo/merge-requests', { csrf_token: csrf(await html('/root/demo/merge-requests/new')), title: 'Mirror a merged change', source: 'feature', target: 'main' });
  await form('/root/demo/merge-requests/1/merge', { csrf_token: csrf(await html('/root/demo/merge-requests/1')), version: '1' });
  await until(() => sql('SELECT status FROM merge_request')[0].status === 'merged', 'MR did not merge');
  await until(() => mirror().status === 'succeeded' && git(remote, ['rev-parse', 'refs/heads/main']) === git(dir, ['rev-parse', 'refs/heads/main']), 'merged commit not mirrored');
  // Browser evidence, desktop/mobile, and native no-JavaScript forms.
  browser = await chromium.launch({ headless: true, ...(process.env.CHROMIUM_EXECUTABLE ? { executablePath: process.env.CHROMIUM_EXECUTABLE } : {}) });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await context.addCookies([{ name: cookie.split('=')[0], value: cookie.slice(cookie.indexOf('=') + 1), url: base }]);
  const page = await context.newPage(); const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.goto(base + route); await page.getByRole('heading', { name: 'Push mirrors', exact: true }).waitFor();
  await page.screenshot({ path: path.join(review, 'desktop.png'), fullPage: true });
  await page.goto(base + edit); await page.getByRole('heading', { name: 'Mirror settings', exact: true }).waitFor();
  await page.screenshot({ path: path.join(review, 'desktop-settings.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForFunction(() => document.querySelector('#app-sidebar').getBoundingClientRect().right <= 1);
  await page.screenshot({ path: path.join(review, 'mobile-settings.png'), fullPage: true });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await page.goto(base + route); await page.screenshot({ path: path.join(review, 'mobile.png'), fullPage: true });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  const native = await browser.newContext({ javaScriptEnabled: false }); await native.addCookies(await context.cookies());
  const nativePage = await native.newPage(); await nativePage.goto(base + edit);
  await nativePage.getByLabel('Enable automatic sync').uncheck(); await nativePage.getByRole('button', { name: 'Save mirror', exact: true }).click();
  await nativePage.waitForURL(base + edit); assert.equal(mirror().status, 'disabled');
  assert.equal(await nativePage.getByLabel('Enable automatic sync').isChecked(), false);
  const oldPublicKey = keyPair().public_key;
  await nativePage.getByText('Rotate SSH key', { exact: true }).click();
  await nativePage.getByRole('button', { name: 'Generate new SSH key', exact: true }).click();
  await nativePage.waitForURL(base + edit);
  assert.equal(mirror().status, 'disabled');
  assert.notEqual(keyPair().public_key, oldPublicKey);
  assert.equal(await nativePage.getByLabel('Public key', { exact: true }).inputValue(), keyPair().public_key);
  assert.ok(!(await nativePage.content()).includes('PRIVATE KEY'));
  fs.writeFileSync(authorized, keyPair().public_key.split(' ').slice(0, 2).join(' '), { mode: 0o600 });
  await nativePage.getByLabel('Enable automatic sync').check();
  await nativePage.getByRole('button', { name: 'Save mirror', exact: true }).click();
  await nativePage.waitForURL(base + edit);
  await until(() => mirror().status === 'succeeded', 'rotated key could not sync');
  assert.deepEqual(fs.readdirSync(path.join(temp, 'repos/.mirrors')).filter(name => name.startsWith('key-') || name.startsWith('snapshot-')), []);
  await native.close(); assert.deepEqual(errors, []);
  fs.writeFileSync(path.join(review, 'receipt.json'), JSON.stringify({ result: 'passed', cases: ['initial branches and annotated tags', 'internal refs excluded', 'real SSH receive hooks', 'branch and tag deletion', 'real MR merge triggers mirror', 'desktop and mobile layouts', 'native disable form', 'database-backed independent SSH identity', 'public-key setup without namespace import key', 'native key rotation and reauthorization', 'temporary key cleanup'], errors }, null, 2));
  console.log('Mirror integration and browser acceptance passed. Screenshots: ' + review);
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  await browser?.close(); if (server && server.exitCode === null) { server.kill('SIGTERM'); await once(server, 'exit'); }
  fs.rmSync(temp, { recursive: true, force: true });
});
