// Isolated local acceptance: no production data or email service is touched.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { execFileSync, spawn } = require('node:child_process');
const { once } = require('node:events');
const { DatabaseSync } = require('node:sqlite');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '..');
const output = path.join(root, '_build/cli-smoke');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-cli-'));
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/moonhub.exe');
const database = path.join(temp, 'moonhub.db');
const password = randomBytes(24).toString('hex');
const env = { ...process.env, DB_PATH: database, MAIL_OUTBOX_DIR: path.join(temp, 'mail') };
let server, browser;
async function until(f, message) {
  for (let i = 0; i < 150; i++) { const result = await f(); if (result) return result; await new Promise(r => setTimeout(r, 100)); }
  throw new Error(message);
}
function query(sql) {
  const db = new DatabaseSync(database, { readOnly: true, timeout: 5000 });
  try { return db.prepare(sql).all(); } finally { db.close(); }
}
async function main() {
  fs.mkdirSync(output, { recursive: true });
  fs.mkdirSync(path.join(temp, 'repos'));
  fs.cpSync(path.join(root, 'db'), path.join(temp, 'db'), { recursive: true });
  fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  const listener = net.createServer();
  await new Promise((resolve, reject) => { listener.once('error', reject); listener.listen(0, '127.0.0.1', resolve); });
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(output, 'server.log'), 'w', 0o600);
  server = spawn(binary, [path.join(temp, 'repos'), '--assets', path.join(root, 'assets'), '--host', '127.0.0.1', '--port', String(port), '--root-user', 'root', '--root-password-file', path.join(temp, 'password')], { cwd: temp, env, stdio: ['ignore', log, log] });
  fs.closeSync(log);
  await until(async () => { if (server.exitCode !== null) throw new Error(fs.readFileSync(path.join(output, 'server.log'), 'utf8')); try { return (await fetch(base + '/-/login')).ok; } catch { return false; } }, 'server did not start');
  let cookie;
  async function form(route, data, expected = 303) {
    const response = await fetch(base + route, { method: 'POST', body: new URLSearchParams(data), headers: cookie ? { Cookie: cookie } : {}, redirect: 'manual' });
    if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
    const text = await response.text();
    assert.equal(response.status, expected, text);
    return text;
  }
  await form('/-/login', { name_key: 'root', password });
  await form('/-/change-password', { new_password: password, confirm_password: password });
  execFileSync(binary, ['repo-create', 'root/demo'], { cwd: temp, env, stdio: 'pipe' });
  const db = new DatabaseSync(database, { timeout: 5000 });
  db.exec(`INSERT INTO "user"(name_key, display_name, password_hash) SELECT 'reviewer', 'Reviewer', password_hash FROM "user" WHERE name_key = 'root';
    INSERT INTO team_member(team_id, user_id, role) SELECT t.id, u.id, 'member' FROM team t JOIN "user" u WHERE t.name_key = 'root' AND u.name_key = 'reviewer';`);
  db.close();
  async function tokenFile(permission, name) {
    const page = await (await fetch(base + '/-/settings/tokens', { headers: { Cookie: cookie } })).text();
    const csrf = page.match(/name="csrf_token" value="([^"]+)"/)[1];
    const created = await form('/-/settings/tokens', { csrf_token: csrf, name, permission, days: '1' }, 200);
    const token = created.match(/value="(mh_[a-f0-9]{64})"/)[1];
    const file = path.join(temp, name + '.token');
    fs.writeFileSync(file, token, { mode: 0o600 });
    return file;
  }
  const write = await tokenFile('write', 'author');
  const execute = await tokenFile('execute', 'runner');
  const merge = await tokenFile('merge', 'merger');
  const cliEnv = { ...env, XDG_CONFIG_HOME: path.join(temp, 'config'), MOONHUB_TOKEN: '', MOONHUB_SERVER: '', MOONHUB_REPOSITORY: '' };
  function cli(args, token = write, expected = 0, extra = {}) {
    const r = require('node:child_process').spawnSync(binary, [...args, '--server', base, '--allow-http', '--repo', 'root/demo', '--token-file', token, '--json'], { cwd: temp, env: { ...cliEnv, ...extra }, encoding: 'utf8', timeout: 30000 });
    assert.equal(r.status, expected, r.stdout + r.stderr);
    assert.ok(!r.stdout.includes(fs.readFileSync(token, 'utf8')), 'token exposed on stdout');
    return expected === 0 ? JSON.parse(r.stdout.trim()) : r;
  }
  const git = (args, input) => execFileSync('git', ['--git-dir=' + path.join(temp, 'repos/root/demo.git'), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', ...args], { input, encoding: 'utf8' }).trim();
  const blob = text => git(['hash-object', '-w', '--stdin'], text);
  const tree = lines => git(['mktree'], lines.join('\n') + '\n');
  const workflow = ['name: CLI fixture', 'on: workflow_dispatch', 'jobs:', '  check:', '    runs-on: self-hosted', '    steps:', '      - run: echo fixture', ''].join('\n');
  const workflows = tree([`100644 blob ${blob(workflow)}\tbuild.yml`]);
  const github = tree([`040000 tree ${workflows}\tworkflows`]);
  const firstTree = tree([`040000 tree ${github}\t.github`, `100644 blob ${blob('base\n')}\tREADME.md`]);
  const initial = git(['commit-tree', firstTree, '-m', 'Base']);
  git(['update-ref', 'refs/heads/main', initial]);
  const featureTree = tree([`040000 tree ${github}\t.github`, `100644 blob ${blob('feature\n')}\tREADME.md`]);
  const source = git(['commit-tree', featureTree, '-p', initial, '-m', 'Feature']);
  git(['update-ref', 'refs/heads/feature', source]);
  cli(['auth', 'status']);
  cli(['auth', 'login']);
  const credentials = path.join(cliEnv.XDG_CONFIG_HOME, 'moonhub/auth.json');
  assert.equal(fs.statSync(credentials).mode & 0o777, 0o600);
  cli(['auth', 'login']); // replacement must also work
  fs.writeFileSync(credentials, '{broken', { mode: 0o600 });
  cli(['auth', 'login']); // explicit credentials must recover corrupt saved state
  assert.equal(cli(['auth', 'status']).username, 'root');
  assert.equal(cli(['auth', 'status'], write, 0, { XDG_CONFIG_HOME: '', HOME: path.join(temp, 'home') }).username, 'root');
  cli(['auth', 'login'], write, 0, { XDG_CONFIG_HOME: '', HOME: path.join(temp, 'home') });
  assert.equal(fs.statSync(path.join(temp, 'home/.config/moonhub/auth.json')).mode & 0o777, 0o600);
  const saved = execFileSync(binary, ['auth', 'status', '--allow-http', '--json'], { cwd: temp, env: cliEnv, encoding: 'utf8' });
  assert.equal(JSON.parse(saved).username, 'root');
  const body = path.join(temp, 'body.md');
  fs.writeFileSync(body, 'Review this CLI workflow.\nSecond line.');
  const issue = cli(['issue', 'create', '--title', 'Track CLI', '--body-file', body, '--assignee', '1']);
  assert.equal(issue.number, '1');
  assert.equal(cli(['issue', 'list']).items.length, 1);
  cli(['issue', 'comment', '1', '--body-file', body]);
  cli(['issue', 'edit', '1', '--title', 'Renamed CLI', '--edit-version', '1']);
  const edited = cli(['issue', 'view', '1']).issue;
  assert.equal(edited.description, fs.readFileSync(body, 'utf8'));
  assert.equal(edited.assignee_id, '1');
  const emptyBody = path.join(temp, 'empty.md');
  fs.writeFileSync(emptyBody, '');
  cli(['issue', 'edit', '1', '--edit-version', edited.edit_version, '--body-file', emptyBody, '--assignee', '0']);
  const cleared = cli(['issue', 'view', '1']).issue;
  assert.equal(cleared.title, 'Renamed CLI');
  assert.equal(cleared.description, '');
  assert.equal(cleared.assignee_id, '0');
  cli(['issue', 'close', '1', '--edit-version', cleared.edit_version]);
  assert.equal(cli(['issue', 'view', '1']).issue.status, 'closed');
  const mr = cli(['mr', 'create', '--title', 'CLI MR', '--source', 'feature', '--target', 'main', '--body-file', body]);
  assert.equal(mr.number, '1');
  assert.equal(mr.version, '1');
  assert.equal(cli(['mr', 'list']).items.length, 1);
  assert.ok(cli(['mr', 'diff', '1', '--version', '1']).patch.includes('+feature'));
  assert.equal(cli(['mr', 'view', '1']).mr.description, fs.readFileSync(body, 'utf8'));
  const reviewerId = query("SELECT id FROM \"user\" WHERE name_key='reviewer'")[0].id;
  cli(['mr', 'request-review', '1', '--reviewer', String(reviewerId), '--version', '1']);
  const rootCookie = cookie;
  cookie = undefined;
  await form('/-/login', { name_key: 'reviewer', password });
  const reviewToken = await tokenFile('write', 'reviewer');
  cli(['mr', 'review', '1', '--decision', 'approved', '--version', '1'], reviewToken);
  cli(['mr', 'review', '1', '--decision', 'approved', '--version', '2'], reviewToken, 1);
  assert.equal(cli(['inbox', 'list']).items.length, 1);
  const notification = cli(['inbox', 'list']).items[0];
  cli(['inbox', 'read', notification.id]);
  assert.equal(cli(['inbox', 'list']).unread, '0');
  cli(['mr', 'merge', '1', '--version', '1'], write, 1);
  cli(['mr', 'merge', '1', '--version', '1'], merge);
  await until(() => query('SELECT status FROM merge_request')[0].status === 'merged', 'CLI merge did not complete');
  const run = cli(['ci', 'run', '--branch', 'main', '--workflow', '.github/workflows/build.yml'], execute);
  assert.equal(cli(['ci', 'view', run.number]).run.status, 'queued');
  cli(['ci', 'cancel', run.number], execute);
  assert.equal(cli(['ci', 'view', run.number]).run.conclusion, 'cancelled');
  assert.equal(cli(['ci', 'list']).items.length, 1);
  cli(['ci', 'rerun', run.number], execute);
  // Use a real stalled HTTP peer to exercise the CLI's request deadline and exit code.
  const stalledSockets = new Set();
  const stalled = net.createServer(socket => {
    stalledSockets.add(socket);
    socket.on('close', () => stalledSockets.delete(socket));
    socket.on('data', () => {});
  });
  await new Promise(resolve => stalled.listen(0, '127.0.0.1', resolve));
  try {
    const client = spawn(binary, ['auth', 'status', '--server', `http://127.0.0.1:${stalled.address().port}`, '--allow-http', '--token-file', write, '--json'], { cwd: temp, env: cliEnv, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    client.stdout.on('data', data => { stdout += data; });
    client.stderr.on('data', data => { stderr += data; });
    const timer = setTimeout(() => client.kill('SIGKILL'), 35000);
    try {
      const [code] = await once(client, 'exit');
      assert.equal(code, 1, stderr);
      assert.equal(stdout, '');
      assert.match(stderr, /API request timed out/);
    } finally { clearTimeout(timer); }
  } finally {
    for (const socket of stalledSockets) socket.destroy();
    await new Promise(resolve => stalled.close(resolve));
  }
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const split = rootCookie.indexOf('=');
  await context.addCookies([{ name: rootCookie.slice(0, split), value: rootCookie.slice(split + 1), url: base }]);
  const page = await context.newPage();
  await page.goto(base + '/-/settings/tokens');
  await page.screenshot({ path: path.join(output, 'tokens-desktop.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForFunction(() => document.querySelector('#app-sidebar').getBoundingClientRect().right <= 1);
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'tokens overflow mobile');
  await page.screenshot({ path: path.join(output, 'tokens-mobile.png'), fullPage: true });
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.getByLabel('Name', { exact: true }).fill('Retain this token request');
  await page.getByLabel('Permission', { exact: true }).selectOption('execute');
  await page.getByLabel('Expires in days', { exact: true }).evaluate(el => el.removeAttribute('max'));
  await page.getByLabel('Expires in days', { exact: true }).fill('366');
  await Promise.all([page.waitForNavigation(), page.getByRole('button', { name: 'Create token', exact: true }).click()]);
  await page.getByRole('alert').waitFor();
  assert.equal(await page.getByLabel('Name', { exact: true }).inputValue(), 'Retain this token request');
  assert.equal(await page.getByLabel('Permission', { exact: true }).inputValue(), 'execute');
  assert.equal(await page.getByLabel('Expires in days', { exact: true }).inputValue(), '366');
  await page.screenshot({ path: path.join(output, 'tokens-error-desktop.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForFunction(() => document.querySelector('#app-sidebar').getBoundingClientRect().right <= 1);
  await page.screenshot({ path: path.join(output, 'tokens-error-mobile.png'), fullPage: true });
  cookie = rootCookie;
  const tokenPage = await (await fetch(base + '/-/settings/tokens', { headers: { Cookie: cookie } })).text();
  const csrf = tokenPage.match(/name="csrf_token" value="([^"]+)"/)[1];
  const id = query("SELECT id FROM access_token WHERE name='author'")[0].id;
  await form(`/-/settings/tokens/${id}/revoke`, { csrf_token: csrf });
  cli(['mr', 'list'], write, 1);
  execFileSync(binary, ['auth', 'logout'], { cwd: temp, env: cliEnv, stdio: 'pipe' });
  assert.ok(!fs.existsSync(credentials));
  fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({ status: 'passed', cases: ['token UI create/revoke and form preservation', 'login replacement corrupt-state recovery empty-XDG fallback and private storage', 'MR create/view/request/review/stale rejection/merge', 'Issue partial edit explicit field clearing comment/close', 'Inbox read', 'CI run/view/cancel/rerun', 'real HTTP deadline and transport exit code', 'desktop/mobile token settings'], secretsPrinted: false }, null, 2));
  console.log('Collaboration CLI acceptance passed.');
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  await browser?.close();
  if (server && server.exitCode === null) {
    const ended = once(server, 'exit'); const timer = setTimeout(() => server.kill('SIGKILL'), 5000);
    server.kill('SIGTERM'); try { await ended; } finally { clearTimeout(timer); }
  }
  fs.rmSync(temp, { recursive: true, force: true });
});
