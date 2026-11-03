// Disposable local acceptance for secret CLI, browser forms and responsive layout.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { execFileSync, spawn, spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const { chromium } = require(require.resolve('playwright', { paths: [path.join(root, 'js')] }));
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/moonhub.exe');
const output = path.join(root, '_build/repository-secrets-smoke');
const captures = path.join(root, '.impeccable/review/repository-secrets');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-secrets-'));
const password = randomBytes(24).toString('hex');
const value = 'disposable-secret-' + randomBytes(16).toString('hex');
const env = { ...process.env, DB_PATH: path.join(temp, 'moonhub.db'), MAIL_OUTBOX_DIR: path.join(temp, 'mail'), XDG_CONFIG_HOME: path.join(temp, 'config'), MOONHUB_SERVER: '', MOONHUB_TOKEN: '', MOONHUB_REPOSITORY: '' };
let server, browser;

async function capture(page, state) {
  assert.equal(await page.locator('.site-header').count(), 1, 'navigation duplicated the page shell');
  assert.equal(await page.locator('#main-content').count(), 1, 'navigation duplicated main content');
  for (const [name, width] of [['desktop', 1280], ['mobile', 390]]) {
    // A fresh page avoids stale fixed-header compositor layers after resizing.
    const shot = await page.context().newPage();
    try {
      await shot.setViewportSize({ width, height: 900 });
      await shot.emulateMedia({ reducedMotion: 'reduce' });
      await shot.goto(page.url());
      await shot.evaluate(() => document.fonts.ready);
      await shot.waitForFunction(() => {
        const sidebar = document.querySelector('#app-sidebar');
        return !sidebar || getComputedStyle(sidebar).position !== 'fixed' || (getComputedStyle(sidebar).visibility === 'hidden' && sidebar.getBoundingClientRect().right <= 1);
      });
      await shot.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      assert.equal(await shot.locator('.site-header').count(), 1);
      assert.equal(await shot.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth), false, `${state}/${name} overflows`);
      await shot.screenshot({ path: path.join(captures, `${state}-${name}.png`), fullPage: true, animations: 'disabled' });
    } finally { await shot.close(); }
  }
}

async function main() {
  fs.mkdirSync(output, { recursive: true });
  fs.mkdirSync(captures, { recursive: true });
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
  let ready = false;
  for (let i = 0; i < 150; i++) {
    if (server.exitCode !== null) throw new Error('local server failed to start');
    try { ready = (await fetch(base + '/-/login')).ok; } catch {}
    if (ready) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.ok(ready, 'local server did not start');
  let cookie;
  async function post(route, fields, expected = 303) {
    const response = await fetch(base + route, { method: 'POST', body: new URLSearchParams(fields), headers: cookie ? { Cookie: cookie } : {}, redirect: 'manual' });
    if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
    assert.equal(response.status, expected, `form ${route}`);
    return response.text();
  }
  await post('/-/login', { name_key: 'root', password });
  await post('/-/change-password', { new_password: password, confirm_password: password });
  execFileSync(binary, ['repo-create', 'root/demo'], { cwd: temp, env, stdio: 'pipe' });
  const git = (args, input) => execFileSync('git', ['--git-dir=' + path.join(temp, 'repos/root/demo.git'), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', ...args], { input, encoding: 'utf8' }).trim();
  const tree = git(['mktree'], '');
  const commit = git(['commit-tree', tree, '-m', 'Secret fixture']);
  git(['update-ref', 'refs/heads/master', commit]);
  const tokenPage = await (await fetch(base + '/-/settings/tokens', { headers: { Cookie: cookie } })).text();
  const csrf = tokenPage.match(/name="csrf_token" value="([^"]+)"/)[1];
  const created = await post('/-/settings/tokens', { csrf_token: csrf, name: 'secret-acceptance', permission: 'write', days: '1' }, 200);
  const token = created.match(/value="(mh_[a-f0-9]{64})"/)[1];
  const tokenFile = path.join(temp, 'access.token');
  const valueFile = path.join(temp, 'secret.txt');
  fs.writeFileSync(tokenFile, token, { mode: 0o600 });
  fs.writeFileSync(valueFile, value, { mode: 0o600 });
  const cli = (args, expected = 0) => {
    const result = spawnSync(binary, [...args, '--server', base, '--allow-http', '--repo', 'root/demo', '--token-file', tokenFile, '--json'], { cwd: temp, env, encoding: 'utf8', timeout: 30000 });
    assert.equal(result.status, expected, `CLI ${args[0]} ${args[1]} failed`);
    assert.ok(!result.stdout.includes(token) && !result.stdout.includes(value), 'CLI exposed credentials');
    return expected === 0 ? JSON.parse(result.stdout.trim()) : null;
  };
  cli(['auth', 'status']);
  assert.deepEqual(cli(['secret', 'list']).items, []);
  const metadata = cli(['secret', 'set', 'MOONCAKES_MOONBITLANG_TOKEN', '--branch', 'master', '--workflow', '.github/workflows/publish.yml', '--body-file', valueFile, '--version', '0']);
  assert.equal(metadata.name, 'MOONCAKES_MOONBITLANG_TOKEN');
  assert.equal(cli(['secret', 'list']).items.length, 1);
  cli(['secret', 'set', metadata.name, '--branch', 'master', '--workflow', '.github/workflows/publish.yml', '--body-file', valueFile, '--version', '0'], 1);
  browser = await chromium.launch({ headless: true, ...(process.env.CHROMIUM_EXECUTABLE ? { executablePath: process.env.CHROMIUM_EXECUTABLE } : {}) });
  const context = await browser.newContext();
  const split = cookie.indexOf('=');
  await context.addCookies([{ name: cookie.slice(0, split), value: cookie.slice(split + 1), url: base }]);
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(base + '/root/demo/settings/secrets');
  await page.getByRole('heading', { name: 'Repository secrets', exact: true }).waitFor();
  assert.ok(!(await page.content()).includes(value));
  await capture(page, 'list');
  await page.getByRole('link', { name: `Edit ${metadata.name}`, exact: true }).click();
  assert.equal(await page.getByLabel('New value', { exact: true }).inputValue(), '');
  await capture(page, 'edit');
  await page.getByLabel('Allowed workflow').fill('invalid');
  await page.getByLabel('New value', { exact: true }).fill(value);
  await page.getByRole('button', { name: 'Save secret', exact: true }).click();
  await page.getByRole('alert').waitFor();
  assert.equal(await page.getByLabel('New value', { exact: true }).inputValue(), '');
  assert.ok(!(await page.content()).includes(value));
  await page.getByLabel('Allowed workflow').fill('.github/workflows/publish.yml');
  await page.getByRole('button', { name: 'Save secret', exact: true }).click();
  await page.getByRole('status').filter({ hasText: 'Secret saved.' }).waitFor();
  await page.getByRole('link', { name: `Delete ${metadata.name}`, exact: true }).click();
  await page.getByRole('heading', { name: 'Delete repository secret' }).waitFor();
  await capture(page, 'delete');
  await page.getByRole('button', { name: 'Delete secret', exact: true }).click();
  await page.getByText('No repository secrets.', { exact: false }).waitFor();
  await capture(page, 'empty');
  assert.deepEqual(cli(['secret', 'list']).items, []);
  assert.deepEqual(errors, []);
  console.log('Repository secret CLI, browser forms and desktop/mobile layout passed.');
  console.log(`Screenshots: ${captures}`);
}

main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close();
  if (server && server.exitCode === null) { server.kill('SIGTERM'); await new Promise(resolve => server.once('exit', resolve)); }
  fs.rmSync(temp, { recursive: true, force: true });
});
