const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { spawn } = require('node:child_process');
const { chromium } = require('playwright');

const repo = path.resolve(__dirname, '..');
const output = path.join(repo, '_build', 'mail-settings-browser');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-mail-settings-'));
const password = randomBytes(24).toString('base64url');
let server;
let browser;
let succeeded = false;

async function availablePort() {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', resolve);
  });
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  return port;
}

async function capture(page, state) {
  const originalViewport = page.viewportSize();
  for (const [name, viewport] of [
    ['desktop', { width: 1280, height: 900 }],
    ['mobile', { width: 390, height: 844 }],
    ['small-mobile', { width: 320, height: 740 }],
  ]) {
    await page.setViewportSize(viewport);
    await page.evaluate(() => document.fonts.ready);
    const layout = await page.evaluate(() => {
      const width = document.documentElement.clientWidth;
      const controls = [...document.querySelectorAll('a, button, summary, select, input:not([type=hidden])')]
        .filter(element => element.checkVisibility());
      const overlaps = [];
      for (let i = 0; i < controls.length; i++) {
        for (let j = i + 1; j < controls.length; j++) {
          const a = controls[i].getBoundingClientRect();
          const b = controls[j].getBoundingClientRect();
          if (Math.min(a.right, b.right) - Math.max(a.left, b.left) > 1 &&
              Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 1) {
            overlaps.push([controls[i].name || controls[i].textContent, controls[j].name || controls[j].textContent]);
          }
        }
      }
      return {
        pageOverflow: document.documentElement.scrollWidth > width,
        outside: controls.filter(element => {
          const rect = element.getBoundingClientRect();
          return rect.left < -1 || rect.right > width + 1;
        }).map(element => element.name || element.textContent),
        overlaps,
      };
    });
    assert.deepEqual(layout, { pageOverflow: false, outside: [], overlaps: [] }, `${state}/${name}`);
    await page.screenshot({ path: path.join(output, `${state}-${name}.png`), fullPage: true });
  }
  await page.setViewportSize(originalViewport);
}

async function main() {
  fs.mkdirSync(output, { recursive: true });
  fs.mkdirSync(path.join(temp, 'repos'));
  fs.cpSync(path.join(repo, 'db'), path.join(temp, 'db'), { recursive: true });
  fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  const port = await availablePort();
  const url = `http://127.0.0.1:${port}`;
  const env = { ...process.env, DB_PATH: path.join(temp, 'moonhub.db'), MAIL_OUTBOX_DIR: path.join(temp, 'mail') };
  delete env.MOONHUB_ROOT_PASSWORD;
  delete env.MOONHUB_ROOT_PASSWORD_FILE;
  delete env.MOONHUB_SSH_PUBLIC_URL;
  const log = fs.openSync(path.join(output, 'server.log'), 'w', 0o600);
  server = spawn(process.env.MOONHUB_BINARY || path.join(repo, '_build/native/debug/build/hackwaly/moonhub/moonhub.exe'), [
    path.join(temp, 'repos'), '--assets', path.join(repo, 'assets'),
    '--host', '127.0.0.1', '--port', String(port), '--root-user', 'preview',
    '--root-password-file', path.join(temp, 'password'),
  ], { cwd: temp, env, detached: true, stdio: ['ignore', log, log] });
  fs.closeSync(log);
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    if (server.exitCode !== null) throw new Error(fs.readFileSync(path.join(output, 'server.log'), 'utf8'));
    try { ready = (await fetch(`${url}/login`)).ok; } catch {}
    if (ready) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert(ready, 'preview server did not start');
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`${url}/login`);
  await page.locator('[name=name_key]').fill('preview');
  await page.locator('[name=password]').fill(password);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL('**/change-password');
  await page.locator('[name=new_password]').fill(password);
  await page.locator('[name=confirm_password]').fill(password);
  await page.locator('form[action="/change-password"] button').click();
  await page.waitForURL(url + '/');
  await page.locator('.account-menu > summary').click();
  await page.locator('.account-menu-panel').getByRole('link', { name: 'Site settings', exact: true }).click();
  const form = page.locator('form[action="/admin/settings/mail"]');
  await form.getByLabel('Transport', { exact: true }).selectOption('smtp');
  await form.getByLabel('SMTP host', { exact: true }).fill('smtp.example.com');
  await form.getByLabel('Username', { exact: true }).fill('mailer@example.com');
  await form.getByLabel('From address', { exact: true }).fill('noreply@example.com');
  await form.getByRole('button', { name: 'Save email settings', exact: true }).click();
  await page.getByRole('alert').filter({ hasText: 'SMTP password is required' }).waitFor();
  assert.equal(await form.getByLabel('SMTP host', { exact: true }).inputValue(), 'smtp.example.com');
  assert.equal(await form.locator('[name=smtp_password]').inputValue(), '');
  await capture(page, 'validation');
  await form.locator('[name=smtp_password]').fill('smtp-test-password');
  await form.getByRole('button', { name: 'Save email settings', exact: true }).click();
  await page.getByText('Email settings saved.', { exact: true }).waitFor();
  assert.equal(await form.locator('[name=smtp_password]').inputValue(), '');
  assert(!(await page.content()).includes('smtp-test-password'));
  await form.getByRole('button', { name: 'Save email settings', exact: true }).click();
  await page.getByText('Password is configured.', { exact: true }).waitFor();
  await page.locator('.mail-advanced summary').click();
  await capture(page, 'saved');
  await form.getByLabel('Transport', { exact: true }).selectOption('file');
  await form.getByRole('button', { name: 'Save email settings', exact: true }).click();
  await page.getByText('Email settings saved.', { exact: true }).waitFor();
  assert.equal(await form.getByLabel('Transport', { exact: true }).inputValue(), 'file');
  assert.deepEqual(errors, []);
  succeeded = true;
  if (process.env.MOONHUB_KEEP_PREVIEW === '1') {
    fs.writeFileSync(path.join(output, 'preview.json'), JSON.stringify({
      url: `${url}/admin/settings/ssh`, username: 'preview', password, pid: server.pid, data: temp,
    }, null, 2) + '\n', { mode: 0o600 });
    console.log(`Preview: ${url}/admin/settings/ssh`);
    console.log(`Login details: ${path.join(output, 'preview.json')}`);
  }
  console.log('SMTP settings browser smoke passed: validation, save, password retention, transport switching, desktop and mobile layouts.');
}

main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close();
  if (server && succeeded && process.env.MOONHUB_KEEP_PREVIEW === '1') {
    server.unref();
  } else {
    if (server && server.exitCode === null) {
      server.kill('SIGTERM');
      await new Promise(resolve => server.once('exit', resolve));
    }
    fs.rmSync(temp, { recursive: true, force: true });
  }
});
