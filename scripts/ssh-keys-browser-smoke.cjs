const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { spawn } = require('node:child_process');
const { chromium } = require('playwright');

const repo = path.resolve(__dirname, '..');
const output = path.join(repo, '_build', 'ssh-keys-browser');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-ssh-keys-ui-'));
const username = 'preview';
const password = randomBytes(24).toString('base64url');
const key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB';
const secondKey = 'ssh-ed25519 ' + Buffer.concat([
  Buffer.from('0000000b7373682d6564323535313900000020', 'hex'),
  Buffer.alloc(32, 2),
]).toString('base64');
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
    const overflow = await page.evaluate(() => {
      const width = document.documentElement.clientWidth;
      const controls = [...document.querySelectorAll('a, button, textarea, input:not([type=hidden])')]
        .filter(element => element.getClientRects().length);
      const overlaps = [];
      for (let i = 0; i < controls.length; i++) {
        for (let j = i + 1; j < controls.length; j++) {
          const a = controls[i].getBoundingClientRect();
          const b = controls[j].getBoundingClientRect();
          if (Math.min(a.right, b.right) - Math.max(a.left, b.left) > 1 &&
              Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 1) {
            overlaps.push([controls[i].textContent || controls[i].name, controls[j].textContent || controls[j].name]);
          }
        }
      }
      return {
        page: document.documentElement.scrollWidth > width,
        controls: controls.filter(element => {
            const rect = element.getBoundingClientRect();
            return rect.left < -1 || rect.right > width + 1;
          }).map(element => element.textContent || element.name),
        overlaps,
      };
    });
    assert.deepEqual(overflow, { page: false, controls: [], overlaps: [] }, `${name}/${state} layout`);
    await page.screenshot({ path: path.join(output, `${name}-${state}.png`), fullPage: true });
  }
}

async function main() {
  fs.mkdirSync(output, { recursive: true });
  fs.mkdirSync(path.join(temp, 'repos'));
  fs.cpSync(path.join(repo, 'db'), path.join(temp, 'db'), { recursive: true });
  fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  const port = await availablePort();
  const url = `http://127.0.0.1:${port}`;
  const env = { ...process.env, DB_PATH: path.join(temp, 'moonhub.db'), MAIL_TRANSPORT: 'file',
    MAIL_OUTBOX_DIR: path.join(temp, 'mail') };
  delete env.MOONHUB_ROOT_PASSWORD;
  delete env.MOONHUB_ROOT_PASSWORD_FILE;
  const log = fs.openSync(path.join(output, 'server.log'), 'w', 0o600);
  server = spawn(process.env.MOONHUB_BINARY || path.join(repo, '_build/native/debug/build/moonhub.exe'), [
    path.join(temp, 'repos'), '--assets', path.join(repo, 'assets'),
    '--host', '127.0.0.1', '--port', String(port), '--root-user', username,
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
  const pageErrors = [];
  page.on('pageerror', error => pageErrors.push(error.message));
  await page.goto(`${url}/login`);
  await page.locator('[name=name_key]').fill(username);
  await page.locator('[name=password]').fill(password);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL('**/change-password');
  await page.locator('[name=new_password]').fill(password);
  await page.locator('[name=confirm_password]').fill(password);
  await page.locator('form[action="/change-password"] button[type=submit]').click();
  await page.waitForURL(url + '/');
  await page.getByRole('link', { name: 'SSH keys', exact: true }).click();
  await page.getByText('No SSH keys.', { exact: true }).waitFor();
  await capture(page, 'empty');

  await page.getByRole('link', { name: 'Add SSH key', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Work laptop');
  await page.getByLabel('Public key (Ed25519)', { exact: true }).fill('not a public key');
  await page.getByRole('button', { name: 'Add SSH key', exact: true }).click();
  await page.getByRole('alert').waitFor();
  assert.equal(await page.getByLabel('Name', { exact: true }).inputValue(), 'Work laptop');
  await capture(page, 'validation');
  await page.getByLabel('Public key (Ed25519)', { exact: true }).fill(key);
  await page.getByRole('button', { name: 'Add SSH key', exact: true }).click();
  await page.waitForURL(`${url}/settings/ssh-keys`);
  await page.getByText('1 active', { exact: true }).waitFor();
  await page.getByRole('link', { name: 'Add SSH key', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('ReleaseWorkstation'.repeat(11));
  await page.getByLabel('Public key (Ed25519)', { exact: true }).fill(secondKey);
  await page.getByRole('button', { name: 'Add SSH key', exact: true }).click();
  await page.waitForURL(`${url}/settings/ssh-keys`);
  await page.getByText('2 active', { exact: true }).waitFor();
  await capture(page, 'keys');

  await page.getByRole('link', { name: 'Revoke Work laptop', exact: true }).click();
  await page.getByRole('heading', { name: 'Revoke SSH key', exact: true }).waitFor();
  await capture(page, 'confirm');
  await page.getByRole('link', { name: 'Cancel', exact: true }).click();
  await page.getByText('2 active', { exact: true }).waitFor();
  await page.getByRole('link', { name: 'Revoke Work laptop', exact: true }).click();
  await page.getByRole('button', { name: 'Revoke SSH key', exact: true }).click();
  await page.waitForURL(`${url}/settings/ssh-keys`);
  await page.getByText('1 active', { exact: true }).waitFor();
  await page.getByText('Revoked', { exact: true }).first().waitFor();
  assert.equal(await page.getByRole('link', { name: 'Revoke Work laptop', exact: true }).count(), 0);
  assert.deepEqual(pageErrors, []);
  succeeded = true;
  if (process.env.MOONHUB_KEEP_PREVIEW === '1') {
    fs.writeFileSync(path.join(output, 'preview.json'), JSON.stringify({
      url: `${url}/settings/ssh-keys`, username, password, pid: server.pid, data: temp,
    }, null, 2) + '\n', { mode: 0o600 });
    console.log(`Preview: ${url}/settings/ssh-keys`);
    console.log(`Login details: ${path.join(output, 'preview.json')}`);
  }
  console.log('Browser smoke test passed: self-service add, validation, list, cancel, revoke; desktop and mobile layouts.');
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
