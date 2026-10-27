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
const previousPreview = path.join(output, 'preview.json');
const password = process.env.MOONHUB_KEEP_PREVIEW === '1' && fs.existsSync(previousPreview)
  ? JSON.parse(fs.readFileSync(previousPreview, 'utf8')).password
  : randomBytes(24).toString('base64url');
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
  const originalViewport = page.viewportSize();
  for (const [name, viewport] of [
    ['desktop', { width: 1280, height: 900 }],
    ['mobile', { width: 390, height: 844 }],
    ['small-mobile', { width: 320, height: 740 }],
  ]) {
    await page.setViewportSize(viewport);
    await page.evaluate(() => document.fonts.ready);
    const overflow = await page.evaluate(() => {
      const width = document.documentElement.clientWidth;
      const panel = document.querySelector('.repo-clone[open] .repo-clone-panel');
      const controls = [...(panel || document).querySelectorAll('a, button, summary, textarea, input:not([type=hidden])')]
        .filter(element => element.checkVisibility());
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
  await page.setViewportSize(originalViewport);
}

async function main() {
  fs.mkdirSync(output, { recursive: true });
  fs.mkdirSync(path.join(temp, 'repos'));
  fs.cpSync(path.join(repo, 'db'), path.join(temp, 'db'), { recursive: true });
  fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  const port = await availablePort();
  const url = `http://127.0.0.1:${port}`;
  const env = { ...process.env, DB_PATH: path.join(temp, 'moonhub.db'),
    MAIL_OUTBOX_DIR: path.join(temp, 'mail') };
  delete env.MOONHUB_ROOT_PASSWORD;
  delete env.MOONHUB_ROOT_PASSWORD_FILE;
  delete env.MOONHUB_SSH_PUBLIC_URL;
  env.MOONHUB_SSH_INTERNAL_URL = 'ssh://git@ssh:2222';
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
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write'], { origin: url });
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
  await page.locator('.account-menu > summary').click();
  await page.locator('.account-menu-panel').getByRole('link', { name: 'SSH keys', exact: true }).click();
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

  await page.getByRole('link', { name: 'Teams', exact: true }).click();
  await page.getByRole('link', { name: 'New team', exact: true }).click();
  await page.locator('[name=name_key]').fill('workshop');
  await page.locator('[name=display_name]').fill('Workshop');
  await page.getByRole('button', { name: 'Create team', exact: true }).click();
  await page.waitForURL(`${url}/workshop`);
  await page.getByRole('link', { name: 'New repository', exact: true }).click();
  await page.getByLabel('Repository name', { exact: true }).fill('example');
  await page.getByLabel('Visibility', { exact: true }).selectOption('private');
  await capture(page, 'repository-new');
  await page.getByRole('button', { name: 'Create repository', exact: true }).click();
  await page.waitForURL(`${url}/workshop/example`, { timeout: 15000 });
  await page.getByText('No files.', { exact: true }).waitFor();
  await page.locator('.repo-clone summary').click();
  await page.getByText('SSH clone address is not configured.', { exact: true }).waitFor();
  await capture(page, 'clone-unconfigured');
  await page.locator('.account-menu > summary').click();
  await page.locator('.account-menu-panel').getByRole('link', { name: 'Site settings', exact: true }).click();
  await page.getByRole('heading', { name: 'SSH access', exact: true }).waitFor();
  await page.getByLabel('Hostname or IP address', { exact: true }).fill('Git.Example.com');
  await page.getByLabel('Port', { exact: true }).fill('12222');
  await page.getByRole('button', { name: 'Save settings', exact: true }).click();
  await page.getByText('SSH settings saved.', { exact: true }).waitFor();
  assert.equal(await page.getByLabel('Hostname or IP address', { exact: true }).inputValue(), 'git.example.com');
  assert.equal(await page.locator('[data-ssh-address-preview]').textContent(), 'ssh://git@git.example.com:12222/team/repository.git');
  await capture(page, 'ssh-address-settings');
  await page.goto(`${url}/workshop/example`);
  await page.locator('.repo-clone summary').click();
  const cloneUrl = 'ssh://git@git.example.com:12222/workshop/example.git';
  assert.equal(await page.locator('[data-clone-url]').inputValue(), cloneUrl);
  await page.locator('[data-clone-copy]:enabled').click();
  await page.getByText('SSH URL copied.', { exact: true }).waitFor();
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), cloneUrl);
  await capture(page, 'clone-copied');
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('.repo-clone').getAttribute('open'), null);
  assert(await page.locator('.repo-clone summary').evaluate(element => element === document.activeElement));
  await page.keyboard.press('Enter');
  await page.evaluate(() => {
    navigator.clipboard.writeText = async () => { throw new DOMException('Permission denied', 'NotAllowedError'); };
  });
  await page.locator('[data-clone-copy]').click();
  await page.getByText('Clipboard unavailable. Address selected.', { exact: true }).waitFor();
  assert.equal(await page.locator('[data-clone-url]').evaluate(element => element.selectionEnd - element.selectionStart), cloneUrl.length);
  await capture(page, 'clone-clipboard-denied');
  await page.locator('h1').click();
  assert.equal(await page.locator('.repo-clone').getAttribute('open'), null);
  await page.goto(`${url}/workshop`);
  await page.getByRole('link', { name: 'example', exact: true }).waitFor();
  await capture(page, 'team-repositories');
  await page.getByRole('link', { name: 'Import via SSH', exact: true }).click();
  await page.getByText('SSH imports are not configured for this team.', { exact: true }).waitFor();
  assert(await page.getByRole('button', { name: 'Import repository', exact: true }).isDisabled());
  await capture(page, 'repository-import');
  await page.goto(`${url}/workshop`);
  assert.deepEqual(pageErrors, []);
  succeeded = true;
  if (process.env.MOONHUB_KEEP_PREVIEW === '1') {
    fs.writeFileSync(path.join(output, 'preview.json'), JSON.stringify({
      url: `${url}/workshop`, username, password, pid: server.pid, data: temp,
    }, null, 2) + '\n', { mode: 0o600 });
    console.log(`Preview: ${url}/workshop`);
    console.log(`Login details: ${path.join(output, 'preview.json')}`);
  }
  console.log('Browser smoke test passed: SSH keys, team repositories, site SSH settings, clone URL copying, clipboard denial and keyboard controls; desktop and mobile layouts.');
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
