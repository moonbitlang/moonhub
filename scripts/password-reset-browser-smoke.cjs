const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { spawn } = require('node:child_process');
const { chromium } = require('playwright');

const repo = path.resolve(__dirname, '..');
const output = path.join(repo, '_build', 'password-reset-browser');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-password-reset-'));
const password = randomBytes(24).toString('base64url');
const newPassword = randomBytes(24).toString('base64url');
const email = 'preview@localhost';
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
  for (const [name, viewport] of [
    ['desktop', { width: 1280, height: 900 }],
    ['mobile', { width: 390, height: 844 }],
    ['small-mobile', { width: 320, height: 740 }],
  ]) {
    await page.setViewportSize(viewport);
    await page.evaluate(() => document.fonts.ready);
    const layout = await page.evaluate(() => {
      const width = document.documentElement.clientWidth;
      const controls = [...document.querySelectorAll('a, button, input:not([type=hidden])')]
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
        overflow: document.documentElement.scrollWidth > width,
        outside: controls.filter(element => {
          const rect = element.getBoundingClientRect();
          return rect.left < -1 || rect.right > width + 1;
        }).map(element => element.name || element.textContent),
        overlaps,
      };
    });
    assert.deepEqual(layout, { overflow: false, outside: [], overlaps: [] }, `${state}/${name}`);
    await page.screenshot({ path: path.join(output, `${state}-${name}.png`), fullPage: true });
  }
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
    try { ready = (await fetch(`${url}/-/login`)).ok; } catch {}
    if (ready) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert(ready, 'preview server did not start');
  browser = await chromium.launch({ headless: true });
  const oldContext = await browser.newContext();
  const oldPage = await oldContext.newPage();
  await oldPage.goto(`${url}/-/login`);
  await oldPage.getByLabel('Username or email', { exact: true }).fill('preview');
  await oldPage.getByLabel('Password', { exact: true }).fill(password);
  await oldPage.getByRole('button', { name: 'Sign in', exact: true }).click();
  await oldPage.waitForURL('**/-/change-password');
  await oldPage.getByLabel('New password', { exact: true }).fill(password);
  await oldPage.getByLabel('Confirm new password', { exact: true }).fill(password);
  await oldPage.getByRole('button', { name: 'Set password', exact: true }).click();
  await oldPage.waitForURL(url + '/');

  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`${url}/-/login`);
  await capture(page, 'login');
  await page.getByRole('link', { name: 'Forgot password?' }).click();
  await capture(page, 'forgot');
  await page.getByLabel('Email', { exact: true }).fill(email);
  await page.getByRole('button', { name: 'Send reset code', exact: true }).click();
  await page.getByRole('status').waitFor();
  await capture(page, 'requested');
  let code;
  for (let attempt = 0; attempt < 100 && !code; attempt++) {
    if (fs.existsSync(path.join(temp, 'mail'))) {
      for (const name of fs.readdirSync(path.join(temp, 'mail'))) {
        const mail = fs.readFileSync(path.join(temp, 'mail', name), 'utf8');
        code = /Reset code: ([a-f0-9]{32})/.exec(mail)?.[1] || code;
      }
    }
    if (!code) await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert(code, 'reset code was not delivered');
  await page.getByLabel('Reset code', { exact: true }).fill(code);
  await page.getByLabel('New password', { exact: true }).fill(newPassword);
  await page.getByLabel('Confirm new password', { exact: true }).fill('DifferentPassword123');
  await page.getByRole('button', { name: 'Reset password', exact: true }).click();
  await page.getByRole('alert').filter({ hasText: 'New passwords do not match.' }).waitFor();
  assert.equal(await page.getByLabel('Email', { exact: true }).inputValue(), email);
  assert.equal(await page.getByLabel('Reset code', { exact: true }).inputValue(), code);
  assert.equal(await page.getByLabel('New password', { exact: true }).inputValue(), '');
  await capture(page, 'validation');
  await page.getByLabel('New password', { exact: true }).fill(newPassword);
  await page.getByLabel('Confirm new password', { exact: true }).fill(newPassword);
  await page.getByRole('button', { name: 'Reset password', exact: true }).click();
  await page.getByRole('heading', { name: 'Password reset', exact: true }).waitFor();
  await capture(page, 'success');
  await oldPage.goto(url + '/');
  await oldPage.waitForURL('**/-/login');
  await page.getByRole('link', { name: 'Sign in', exact: true }).click();
  await page.getByLabel('Username or email', { exact: true }).fill(`  ${email.toUpperCase()}  `);
  await page.getByLabel('Password', { exact: true }).fill(password);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.getByRole('alert').filter({ hasText: 'Invalid username, email, or password.' }).waitFor();
  assert.equal(await page.getByLabel('Username or email', { exact: true }).inputValue(), email.toUpperCase());
  assert.equal(await page.getByLabel('Password', { exact: true }).inputValue(), '');
  await capture(page, 'login-validation');
  await page.getByLabel('Password', { exact: true }).fill(newPassword);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL(url + '/');
  const noJs = await browser.newContext({ javaScriptEnabled: false });
  const fallback = await noJs.newPage();
  await fallback.goto(`${url}/-/forgot-password`);
  await fallback.getByLabel('Email', { exact: true }).fill('unknown@example.com');
  await fallback.getByRole('button', { name: 'Send reset code', exact: true }).click();
  await fallback.getByRole('status').waitFor();
  assert.equal(await fallback.locator('form').getAttribute('action'), '/-/reset-password');
  assert.deepEqual(errors, []);
  succeeded = true;
  if (process.env.MOONHUB_KEEP_PREVIEW === '1') {
    fs.writeFileSync(path.join(output, 'preview.json'), JSON.stringify({
      url: `${url}/-/forgot-password`, username: 'preview', password: newPassword, pid: server.pid, data: temp,
    }, null, 2) + '\n', { mode: 0o600 });
    console.log(`Preview: ${url}/-/forgot-password`);
  }
  console.log('Password recovery browser smoke passed: file delivery, validation, password reset, session revocation, email login, old-password rejection, no-JS forms, and 18 desktop/mobile screenshots.');
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
