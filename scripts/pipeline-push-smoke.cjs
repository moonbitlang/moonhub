const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { execFileSync, spawn } = require('node:child_process');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const output = path.join(root, '_build/pipeline-push-smoke');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-push-'));
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/hackwaly/moonhub/moonhub.exe');
const password = randomBytes(24).toString('hex');
const env = { ...process.env, DB_PATH: path.join(temp, 'moonhub.db'), MOONHUB_REPO_ROOT: path.join(temp, 'repos'),
  MOONHUB_BIN: binary, MOONHUB_HOOKS_PATH: path.join(temp, 'hooks'), MAIL_OUTBOX_DIR: path.join(temp, 'mail') };
let base, port, server, browser, keep = false, cookie;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const cli = (args, input) => execFileSync(binary, args, { cwd: root, env, input, encoding: 'utf8', timeout: 20000 }).trim();

async function start() {
  const log = fs.openSync(path.join(output, 'server.log'), 'a', 0o600);
  server = spawn(binary, [env.MOONHUB_REPO_ROOT, '--assets', path.join(root, 'assets'), '--host', '127.0.0.1', '--port', String(port), '--root-user', 'root', '--root-password-file', path.join(temp, 'password')], { cwd: root, env, detached: true, stdio: ['ignore', log, log] });
  fs.closeSync(log);
  for (let i = 0; i < 100; i++) {
    if (server.exitCode !== null) throw new Error(fs.readFileSync(path.join(output, 'server.log'), 'utf8'));
    try { if ((await fetch(base + '/-/login')).ok) return; } catch {}
    await delay(100);
  }
  throw new Error('server did not start');
}
async function stop() {
  if (!server || server.exitCode !== null) return;
  const exited = new Promise(resolve => server.once('exit', resolve));
  process.kill(-server.pid, 'SIGTERM');
  await exited;
}
async function request(route, fields) {
  const response = await fetch(base + route, { method: fields ? 'POST' : 'GET', redirect: 'manual',
    headers: cookie ? { Cookie: cookie } : {}, body: fields ? new URLSearchParams(fields) : undefined, signal: AbortSignal.timeout(10000) });
  if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
  return { status: response.status, body: await response.text() };
}
async function waitRuns(count) {
  for (let i = 0; i < 100; i++) {
    const response = await request('/root/demo/pipelines');
    const links = [...response.body.matchAll(/href="\/root\/demo\/pipelines\/(\d+)"/g)].map(match => match[1]);
    if (links.length === count) return links;
    if (i === 99) throw new Error(`expected ${count} runs, got ${links.length}: ${response.body}`);
    await delay(100);
  }
}

async function main() {
  fs.mkdirSync(output, { recursive: true });
  fs.mkdirSync(env.MOONHUB_REPO_ROOT);
  fs.mkdirSync(env.MOONHUB_HOOKS_PATH);
  for (const name of ['pre-receive', 'reference-transaction']) {
    const destination = path.join(env.MOONHUB_HOOKS_PATH, name);
    fs.copyFileSync(path.join(root, 'deploy/hooks', name), destination);
    fs.chmodSync(destination, 0o755);
  }
  fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  const listener = net.createServer();
  await new Promise((resolve, reject) => { listener.once('error', reject); listener.listen(0, '127.0.0.1', resolve); });
  port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  base = `http://127.0.0.1:${port}`;
  await start();
  assert.equal((await request('/-/login', { name_key: 'root', password })).status, 303);
  assert.equal((await request('/-/change-password', { new_password: password, confirm_password: password })).status, 303);
  cli(['repo-create', 'root/demo']);
  const key = cli(['ssh-key-add', 'root'], 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB\n').split('\t')[0];
  // Only SSH transport is replaced; receive-pack, the authenticated command,
  // deployed pre-receive/reference-transaction hooks and durable DB are real.
  const transport = path.join(temp, 'ssh');
  fs.writeFileSync(transport, '#!/bin/sh\nfor arg do SSH_ORIGINAL_COMMAND=$arg; done\nexport SSH_ORIGINAL_COMMAND\nexec "$MOONHUB_BIN" ssh-serve "$MOONHUB_TEST_KEY_ID"\n', { mode: 0o700 });
  const source = path.join(temp, 'source');
  fs.mkdirSync(source);
  const git = args => execFileSync('git', args, { cwd: source, env: { ...env, GIT_SSH: transport, GIT_SSH_VARIANT: 'simple', MOONHUB_TEST_KEY_ID: key }, encoding: 'utf8', timeout: 30000 }).trim();
  git(['init', '-q', '-b', 'main']);
  git(['config', 'user.name', 'Push test']);
  git(['config', 'user.email', 'test@example.invalid']);
  fs.mkdirSync(path.join(source, '.github/workflows'), { recursive: true });
  const workflow = name => `name: ${name}\non:\n  push:\n    branches: [main]\n  workflow_dispatch:\njobs:\n  check:\n    runs-on: [self-hosted, linux]\n    steps:\n      - run: echo ${name}\n`;
  fs.writeFileSync(path.join(source, '.github/workflows/check.yml'), workflow('First workflow'));
  fs.writeFileSync(path.join(source, '.github/workflows/other.yml'), workflow('Second workflow'));
  const commit = message => { git(['add', '.']); git(['commit', '-qm', message]); return git(['rev-parse', 'HEAD']); };
  const push = (reference = 'main') => git(['push', 'test-host:/root/demo.git', `HEAD:refs/heads/${reference}`]);
  commit('disabled');
  push();
  await waitRuns(0);
  browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext();
  const split = cookie.indexOf('=');
  await ctx.addCookies([{ name: cookie.slice(0, split), value: cookie.slice(split + 1), url: base }]);
  const page = await ctx.newPage();
  await page.goto(base + '/root/demo/pipelines');
  assert.equal(await page.getByLabel('Run push workflows', { exact: true }).isChecked(), false);
  await page.getByLabel('Run push workflows', { exact: true }).check();
  await page.getByRole('button', { name: 'Save settings', exact: true }).click();
  await page.waitForURL(base + '/root/demo/pipelines');
  assert.equal(await page.getByLabel('Run push workflows', { exact: true }).isChecked(), true);
  await stop();
  fs.writeFileSync(path.join(source, 'README.md'), 'first\n');
  const first = commit('first enabled push');
  push();
  fs.writeFileSync(path.join(source, 'README.md'), 'second\n');
  const second = commit('second enabled push');
  push();
  await start();
  await waitRuns(4);
  for (const [number, sha] of [[1, first], [2, first], [3, second], [4, second]]) {
    const run = await request(`/root/demo/pipelines/${number}`);
    assert.equal(run.status, 200);
    assert.ok(run.body.includes(sha), `run ${number} did not keep its own SHA`);
  }
  await stop();
  await start();
  await waitRuns(4);
  push(); // An up-to-date push must not produce another run.
  await waitRuns(4);
  push('feature');
  await delay(1500);
  await waitRuns(4);
  git(['tag', 'v1']);
  git(['push', 'test-host:/root/demo.git', 'refs/tags/v1']);
  git(['push', 'test-host:/root/demo.git', ':refs/heads/feature']);
  await delay(1500);
  await waitRuns(4);
  git(['push', '--force', 'test-host:/root/demo.git', `${first}:refs/heads/main`]);
  await waitRuns(6);
  assert.ok((await request('/root/demo/pipelines/5')).body.includes(first), 'force push did not preserve its pinned SHA');
  assert.ok((await request('/root/demo/pipelines/6')).body.includes(first));
  await page.goto(base + '/root/demo/pipelines');
  await page.getByLabel('Run push workflows', { exact: true }).uncheck();
  await page.getByRole('button', { name: 'Save settings', exact: true }).click();
  await page.waitForURL(base + '/root/demo/pipelines');
  fs.writeFileSync(path.join(source, 'README.md'), 'disabled again\n');
  commit('disabled again');
  push();
  await delay(1500);
  await waitRuns(6);
  for (const width of [1280, 390]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForFunction(() => {
      const sidebar = document.querySelector('#app-sidebar');
      return !sidebar || getComputedStyle(sidebar).position !== 'fixed' ||
        (getComputedStyle(sidebar).visibility === 'hidden' && sidebar.getBoundingClientRect().right <= 1);
    });
    await page.screenshot({ path: path.join(output, `push-${width}.png`), fullPage: true });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth), false);
  }
  if (process.env.MOONHUB_KEEP_PREVIEW === '1') {
    fs.writeFileSync(path.join(output, 'preview.json'), JSON.stringify({ base, pid: server.pid, username: 'root', passwordFile: path.join(temp, 'password'), directory: temp }, null, 2), { mode: 0o600 });
    keep = true;
    server.unref();
    console.log(`Push preview retained: ${base}/root/demo/pipelines; login: ${path.join(output, 'preview.json')}`);
  }
  console.log('Push smoke passed: real receive-pack and deployed hooks, opt-in settings, two offline pushes, multiple workflows, exact SHAs, restart recovery, no-op deduplication, branch filtering, force push, ignored tags/deletions and disabled triggers.');
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close();
  if (!keep) { await stop(); fs.rmSync(temp, { recursive: true, force: true }); }
});
