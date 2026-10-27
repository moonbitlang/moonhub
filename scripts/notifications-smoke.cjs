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
const output = path.join(root, '_build/notifications-smoke');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-notifications-'));
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/hackwaly/moonhub/moonhub.exe');
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
  async function form(route, data) {
    const response = await fetch(base + route, { method: 'POST', body: new URLSearchParams(data), headers: cookie ? { Cookie: cookie } : {}, redirect: 'manual' });
    if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
    assert.equal(response.status, 303, await response.text());
  }
  await form('/-/login', { name_key: 'root', password });
  await form('/-/change-password', { new_password: password, confirm_password: password });
  execFileSync(binary, ['repo-create', 'root/demo'], { cwd: temp, env, stdio: 'pipe' });
  const db = new DatabaseSync(database, { timeout: 5000 });
  db.exec(`INSERT INTO "user"(name_key, display_name, password_hash, email) SELECT 'reviewer', 'Reviewer', password_hash, 'reviewer@example.invalid' FROM "user" WHERE name_key = 'root';
    INSERT INTO team_member(team_id, user_id, role) SELECT t.id, u.id, 'member' FROM team t JOIN "user" u WHERE t.name_key = 'root' AND u.name_key = 'reviewer';`);
  db.close();
  const git = (args, input) => execFileSync('git', ['--git-dir=' + path.join(temp, 'repos/root/demo.git'), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', ...args], { input, encoding: 'utf8' }).trim();
  const blob = text => git(['hash-object', '-w', '--stdin'], text);
  const tree = text => git(['mktree'], `100644 blob ${blob(text)}\tREADME.md\n`);
  const initial = git(['commit-tree', tree('base\n'), '-m', 'Base']);
  git(['update-ref', 'refs/heads/main', initial]);
  const first = git(['commit-tree', tree('first\n'), '-p', initial, '-m', 'Feature']);
  git(['update-ref', 'refs/heads/feature', first]);
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const split = cookie.indexOf('=');
  await context.addCookies([{ name: cookie.slice(0, split), value: cookie.slice(split + 1), url: base }]);
  const page = await context.newPage();
  page.setDefaultTimeout(10000);
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(base + '/root/demo/merge-requests/new');
  await page.locator('select[name=source]').selectOption('feature');
  await page.locator('select[name=target]').selectOption('main');
  await page.locator('input[name=title]').fill('Make repository notifications useful for every reviewer');
  await page.getByRole('button', { name: 'Create merge request', exact: true }).click();
  const mrUrl = base + '/root/demo/merge-requests/1';
  await page.waitForURL(mrUrl);
  await page.locator('select[name=reviewer]').selectOption(String(query("SELECT id FROM \"user\" WHERE name_key = 'reviewer'")[0].id));
  await page.getByRole('button', { name: 'Request review', exact: true }).click();
  await page.waitForURL(mrUrl);
  await page.screenshot({ path: path.join(output, 'review-desktop.png'), fullPage: true });
  const reviewerContext = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const reviewer = await reviewerContext.newPage();
  reviewer.setDefaultTimeout(10000);
  reviewer.on('pageerror', e => errors.push(e.message));
  await reviewer.goto(base + '/-/login');
  await reviewer.locator('input[name=name_key]').fill('reviewer');
  await reviewer.locator('input[name=password]').fill(password);
  await reviewer.getByRole('button', { name: 'Sign in', exact: true }).click();
  await reviewer.waitForURL(base + '/');
  await reviewer.goto(base + '/-/notifications');
  await reviewer.getByRole('button', { name: 'Read and open', exact: true }).waitFor();
  await reviewer.screenshot({ path: path.join(output, 'inbox-desktop.png'), fullPage: true });
  for (const [name, targetPage] of [['review', page], ['inbox', reviewer]]) {
    await targetPage.setViewportSize({ width: 390, height: 844 });
    await targetPage.waitForFunction(() => document.querySelector('#app-sidebar').getBoundingClientRect().right <= 1);
    await targetPage.evaluate(() => scrollTo(0, 0));
    assert.ok(await targetPage.evaluate(() => document.documentElement.scrollWidth <= innerWidth), name + ' overflows mobile');
    await targetPage.screenshot({ path: path.join(output, name + '-mobile.png'), fullPage: true });
  }
  await reviewer.getByRole('button', { name: 'Read and open', exact: true }).click();
  await reviewer.waitForURL(mrUrl + '?version=1');
  await reviewer.locator('select[name=decision]').selectOption('changes_requested');
  await reviewer.locator('textarea[name=body]').fill('Please cover the new-version notification path.');
  await Promise.all([reviewer.waitForURL(mrUrl), reviewer.getByRole('button', { name: 'Submit review', exact: true }).click()]);
  await page.goto(base + '/-/notifications');
  assert.equal(query('SELECT decision FROM merge_review')[0]?.decision, 'changes_requested');
  assert.ok(query("SELECT * FROM collaboration_notification_visible WHERE kind = 'changes_requested'").length > 0, JSON.stringify(query('SELECT * FROM collaboration_event')));
  await page.screenshot({ path: path.join(output, 'author-updates.png'), fullPage: true });
  await page.getByText('Changes requested', { exact: false }).waitFor();
  const second = git(['commit-tree', tree('second\n'), '-p', first, '-m', 'Fix review']);
  git(['update-ref', 'refs/heads/feature', second]);
  await until(() => query('SELECT current_version FROM merge_request')[0].current_version === 2, 'background review refresh did not detect push');
  await reviewer.goto(base + '/-/notifications?filter=reviews');
  await reviewer.getByRole('link', { name: 'Make repository notifications useful for every reviewer', exact: true }).click();
  await reviewer.locator('select[name=decision]').selectOption('approved');
  await Promise.all([reviewer.waitForURL(mrUrl), reviewer.getByRole('button', { name: 'Submit review', exact: true }).click()]);
  await page.goto(mrUrl);
  await page.getByRole('button', { name: 'Merge request', exact: true }).click();
  await until(() => query('SELECT status FROM merge_request')[0].status === 'merged', 'merge did not complete');
  await reviewer.goto(base + '/-/notifications');
  await reviewer.getByText('Merge request merged', { exact: false }).waitFor();
  assert.deepEqual(errors, []);
  fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({ status: 'passed', cases: ['request review', 'read and open', 'changes requested', 'background version refresh', 'review approved', 'merge notification', 'desktop/mobile layout'], pageErrors: errors }, null, 2));
  console.log('Notifications browser acceptance passed.');
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  await browser?.close();
  if (server && server.exitCode === null) {
    const ended = once(server, 'exit'); const timer = setTimeout(() => server.kill('SIGKILL'), 5000);
    server.kill('SIGTERM'); try { await ended; } finally { clearTimeout(timer); }
  }
  fs.rmSync(temp, { recursive: true, force: true });
});
