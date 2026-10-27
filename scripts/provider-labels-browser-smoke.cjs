const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { execFileSync, spawn } = require('node:child_process');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const output = path.join(root, '_build', 'provider-labels-browser');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-provider-labels-'));
const password = randomBytes(24).toString('hex');
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/hackwaly/moonhub/moonhub.exe');
const env = { ...process.env, DB_PATH: path.join(temp, 'moonhub.db'), MAIL_OUTBOX_DIR: path.join(temp, 'mail') };
let server, browser, keep = false;

async function capture(page, state) {
  for (const [name, width] of [['desktop', 1280], ['mobile', 390], ['small-mobile', 320]]) {
    await page.setViewportSize({ width, height: 900 });
    await page.evaluate(() => document.fonts.ready);
    await page.waitForFunction(() => {
      const sidebar = document.querySelector('#app-sidebar');
      if (!sidebar || getComputedStyle(sidebar).position !== 'fixed') return true;
      return getComputedStyle(sidebar).visibility === 'hidden' && sidebar.getBoundingClientRect().right <= 1;
    });
    const layout = await page.evaluate(() => {
      const width = document.documentElement.clientWidth;
      const controls = [...document.querySelectorAll('main a, main button, main select, main input:not([type=hidden])')].filter(e => e.checkVisibility());
      const outside = controls.filter(e => { const r = e.getBoundingClientRect(); return r.left < -1 || r.right > width + 1; }).map(e => e.textContent || e.id);
      const overlaps = [];
      for (let i = 0; i < controls.length; i++) for (let j = i + 1; j < controls.length; j++) {
        if (controls[i].contains(controls[j]) || controls[j].contains(controls[i])) continue;
        const a = controls[i].getBoundingClientRect(), b = controls[j].getBoundingClientRect();
        if (Math.min(a.right, b.right) - Math.max(a.left, b.left) > 1 && Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 1) overlaps.push([controls[i].id, controls[j].id]);
      }
      return { overflow: document.documentElement.scrollWidth > width, outside, overlaps };
    });
    assert.deepEqual(layout, { overflow: false, outside: [], overlaps: [] }, `${state}/${name}`);
    await page.screenshot({ path: path.join(output, `${state}-${name}.png`), fullPage: true });
  }
}

async function main() {
  fs.mkdirSync(output, { recursive: true });
  fs.mkdirSync(path.join(temp, 'repos'));
  fs.cpSync(path.join(root, 'db'), path.join(temp, 'db'), { recursive: true });
  fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  const listener = net.createServer();
  await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(output, 'server.log'), 'w', 0o600);
  server = spawn(binary, [path.join(temp, 'repos'), '--assets', path.join(root, 'assets'), '--host', '127.0.0.1', '--port', String(port), '--root-user', 'root', '--root-password-file', path.join(temp, 'password')], {
    cwd: temp, env, detached: true, stdio: ['ignore', log, log],
  });
  fs.closeSync(log);
  let ready = false;
  for (let i = 0; i < 100; i++) {
    if (server.exitCode !== null) throw new Error(fs.readFileSync(path.join(output, 'server.log'), 'utf8'));
    try { ready = (await fetch(base + '/-/login')).ok; } catch {}
    if (ready) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.ok(ready, 'local test server never started');
  let cookie;
  async function post(route, fields) {
    const response = await fetch(base + route, { method: 'POST', redirect: 'manual', headers: cookie ? { Cookie: cookie } : {}, body: new URLSearchParams(fields) });
    if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
    await response.text();
    assert.equal(response.status, 303);
  }
  await post('/-/login', { name_key: 'root', password });
  await post('/-/change-password', { new_password: password, confirm_password: password });
  const tokenFile = path.join(temp, 'provider-token');
  fs.writeFileSync(tokenFile, randomBytes(32).toString('hex'), { mode: 0o600 });
  execFileSync(binary, ['pipeline-provider-create', '--name', 'dind', '--token-file', tokenFile, '--admin', 'root'], { cwd: temp, env, stdio: 'pipe' });
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const split = cookie.indexOf('=');
  await context.addCookies([{ name: cookie.slice(0, split), value: cookie.slice(split + 1), url: base }]);
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(base + '/-/admin/pipelines/providers');
  await page.getByRole('link', { name: 'Edit labels for dind', exact: true }).click();
  const labels = page.getByLabel('Labels', { exact: true });
  assert.equal(await labels.inputValue(), 'linux,self-hosted');
  await capture(page, 'edit');
  const invalid = 'self-hosted,linux,"<bad>';
  await labels.fill(invalid);
  await page.getByRole('button', { name: 'Save labels', exact: true }).click();
  await page.getByRole('alert').waitFor();
  assert.equal(await labels.inputValue(), invalid, 'failed form lost or double-escaped input');
  await capture(page, 'invalid');
  await labels.fill('SELF-HOSTED, linux, moonhub-build');
  await page.getByRole('button', { name: 'Save labels', exact: true }).click();
  await page.getByRole('status').filter({ hasText: 'Provider labels saved.' }).waitFor();
  await page.getByText('linux, moonhub-build, self-hosted', { exact: false }).waitFor();
  await capture(page, 'saved');
  await page.getByRole('link', { name: 'Edit labels for dind', exact: true }).click();
  assert.equal(await labels.inputValue(), 'linux,moonhub-build,self-hosted');
  await labels.fill('self-hosted,linux');
  await page.getByRole('link', { name: 'Cancel', exact: true }).click();
  await page.getByRole('link', { name: 'Edit labels for dind', exact: true }).click();
  assert.equal(await labels.inputValue(), 'linux,moonhub-build,self-hosted', 'cancel changed labels');
  await page.getByRole('link', { name: 'Cancel', exact: true }).click();
  await page.getByRole('button', { name: 'Pause', exact: true }).click();
  await page.getByRole('link', { name: 'Edit labels for dind', exact: true }).click();
  await labels.fill('self-hosted,linux');
  await page.getByRole('button', { name: 'Save labels', exact: true }).click();
  await page.getByRole('button', { name: 'Resume', exact: true }).waitFor();
  execFileSync(binary, ['repo-create', 'root/demo'], { cwd: temp, env, stdio: 'pipe' });
  await page.getByRole('link', { name: 'Edit access for dind', exact: true }).click();
  const scope = page.getByLabel('Repository scope', { exact: true });
  const repositories = page.getByLabel('Repositories (selected scope only)', { exact: true });
  assert.equal(await scope.inputValue(), 'selected');
  await repositories.fill('root/<missing>');
  await page.getByRole('button', { name: 'Save access', exact: true }).click();
  await page.getByRole('alert').waitFor();
  assert.equal(await repositories.inputValue(), 'root/<missing>');
  await capture(page, 'access-invalid');
  await repositories.fill('root/demo');
  await page.getByRole('button', { name: 'Save access', exact: true }).click();
  await page.getByText('Selected repositories: root/demo', { exact: true }).waitFor();
  await page.getByRole('link', { name: 'Edit access for dind', exact: true }).click();
  await scope.selectOption('all');
  await capture(page, 'access-edit');
  await page.getByRole('button', { name: 'Save access', exact: true }).click();
  await page.getByText('All repositories (including new repositories)', { exact: true }).waitFor();
  await page.getByRole('button', { name: 'Resume', exact: true }).waitFor();
  await capture(page, 'access-shared');
  await page.getByRole('link', { name: 'Edit access for dind', exact: true }).click();
  assert.equal(await repositories.inputValue(), '');
  await scope.selectOption('selected');
  await page.getByRole('button', { name: 'Save access', exact: true }).click();
  await page.getByText('Selected repositories: none', { exact: true }).waitFor();
  await page.getByText('Never connected', { exact: true }).waitFor();
  assert.deepEqual(errors, []);
  if (process.env.MOONHUB_KEEP_PREVIEW === '1') {
    fs.writeFileSync(path.join(output, 'preview.json'), JSON.stringify({ base, pid: server.pid, directory: temp, username: 'root', passwordFile: path.join(temp, 'password') }, null, 2), { mode: 0o600 });
    keep = true;
    server.unref();
    console.log(`Local provider-labels preview retained: ${base}/-/admin/pipelines/providers; credentials: ${path.join(output, 'preview.json')}`);
  }
  console.log('Provider browser tests passed: labels, selected/all repository access, validation round-trip, save, cancel, paused state, desktop/mobile layout.');
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close();
  if (!keep) {
    if (server && server.exitCode === null) {
      const exited = new Promise(resolve => server.once('exit', resolve));
      process.kill(-server.pid, 'SIGTERM');
      await exited;
    }
    fs.rmSync(temp, { recursive: true, force: true });
  }
});
