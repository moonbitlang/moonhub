const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { execFileSync, spawn } = require('node:child_process');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const output = path.join(root, '_build', 'pipeline-logs-browser');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-pipeline-logs-'));
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/moonhub.exe');
const env = { ...process.env, DB_PATH: path.join(temp, 'moonhub.db'), MAIL_OUTBOX_DIR: path.join(temp, 'mail') };
const password = randomBytes(24).toString('hex');
let server, browser, base, cookie, keep = false;
const errors = [];

async function form(route, fields) {
  const response = await fetch(base + route, {
    method: 'POST', redirect: 'manual', headers: cookie ? { Cookie: cookie } : {},
    body: new URLSearchParams(fields), signal: AbortSignal.timeout(10000),
  });
  if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
  await response.text();
  assert.equal(response.status, 303);
}

async function api(route, token, fields = {}) {
  const response = await fetch(base + '/-/runner-api/v1' + route, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ version: 1, ...fields }), signal: AbortSignal.timeout(10000),
  });
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  return body;
}

async function context(options = {}) {
  const context = await browser.newContext(options);
  const split = cookie.indexOf('=');
  await context.addCookies([{ name: cookie.slice(0, split), value: cookie.slice(split + 1), url: base }]);
  context.on('page', page => {
    page.setDefaultTimeout(10000);
    page.on('pageerror', error => errors.push(error.message));
  });
  return context;
}

async function dispatch(page) {
  await page.goto(base + '/root/demo/pipelines/new');
  await page.getByLabel('Branch', { exact: true }).selectOption('main');
  await page.getByLabel('Workflow', { exact: true }).selectOption('.github/workflows/build.yml');
  await page.getByRole('button', { name: 'Run workflow', exact: true }).click();
  await page.waitForURL(/\/pipelines\/\d+$/);
  return new URL(page.url()).pathname;
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
  base = `http://127.0.0.1:${port}`;
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
  await form('/-/login', { name_key: 'root', password });
  await form('/-/change-password', { new_password: password, confirm_password: password });
  const cli = args => execFileSync(binary, args, { cwd: temp, env, stdio: 'pipe' });
  cli(['repo-create', 'root/demo']);
  const git = (args, input) => execFileSync('git', ['--git-dir=' + path.join(temp, 'repos/root/demo.git'), '-c', 'user.name=Preview', '-c', 'user.email=preview@example.invalid', ...args], { input, encoding: 'utf8' }).trim();
  const workflow = 'name: Log refresh preview\non: workflow_dispatch\njobs:\n' + ['build', 'lint'].map(job =>
    `  ${job}:\n    runs-on: [self-hosted, linux]\n    steps:\n      - id: check\n        run: echo preview\n`).join('');
  const blob = git(['hash-object', '-w', '--stdin'], workflow);
  const workflows = git(['mktree'], `100644 blob ${blob}\tbuild.yml\n`);
  const github = git(['mktree'], `040000 tree ${workflows}\tworkflows\n`);
  const tree = git(['mktree'], `040000 tree ${github}\t.github\n`);
  const commit = git(['commit-tree', tree, '-m', 'Log refresh preview']);
  git(['update-ref', 'refs/heads/main', commit]);
  const providers = ['build', 'lint'].map(name => {
    const token = randomBytes(32).toString('hex');
    const file = path.join(temp, name + '-token');
    fs.writeFileSync(file, token, { mode: 0o600 });
    cli(['pipeline-provider-create', '--name', name, '--token-file', file, '--repositories', 'root/demo']);
    return token;
  });
  browser = await chromium.launch({ headless: true });
  const setup = await context();
  const setupPage = await setup.newPage();
  const route = await dispatch(setupPage);
  const attempts = [];
  for (const provider of providers) {
    const token = randomBytes(32).toString('hex');
    const { assignment } = await api('/claims', provider, { request_id: randomBytes(16).toString('hex'), attempt_token: token });
    assert.ok(assignment);
    const endpoint = '/attempts/' + assignment.attempt_id;
    await api(endpoint + '/start', token, { execution_id: randomBytes(16).toString('hex') });
    await api(endpoint + '/steps', token, { step_id: 'check', state: 'running', exit_code: 0 });
    await api(endpoint + '/logs', token, { sequence: '1', step_id: 'check', stream: 'stdout', text: Array.from({ length: 200 }, (_, i) => `preview log line ${i}\n`).join('') });
    attempts.push({ token, endpoint, sequence: 1 });
  }
  await setup.close();
  const active = attempts[0];
  for (const width of [1280, 390]) {
    const ctx = await context({ viewport: { width, height: 900 } });
    const page = await ctx.newPage();
    const requests = [];
    let navigations = 0;
    page.on('request', request => {
      if (request.isNavigationRequest() && request.frame() === page.mainFrame()) navigations++;
      if (request.url().startsWith(base + route + '/') && /\/updates$|\/logs\?/.test(request.url())) requests.push(request.url());
    });
    const response = await page.goto(base + route);
    assert.equal(response.headers()['refresh'], undefined);
    const logs = page.locator('.pipeline-logs');
    assert.equal(await logs.count(), 2);
    assert.equal(await logs.nth(0).locator('summary').count(), 0, 'whole-log folding should be absent');
    await page.evaluate(() => window.scrollTo(0, 180));
    assert.ok(await logs.nth(0).locator('pre').evaluate(e => e.scrollHeight <= e.clientHeight + 1), 'nested vertical log scroll');
    await page.evaluate(() => { window.originalLog = document.querySelector('.pipeline-logs'); });
    const text = `new output ${width} <script>window.logExecuted=true</script>\n`;
    await api(active.endpoint + '/logs', active.token, { sequence: String(++active.sequence), step_id: 'check', stream: 'stdout', text });
    await page.waitForFunction(text => document.querySelector('.pipeline-logs pre').textContent.includes(text), text);
    for (let round = 0; round < 2; round++) {
      await page.waitForResponse(response => response.url() === base + route + '/updates');
      assert.equal(await logs.nth(0).isVisible(), true, 'polling hid selected logs');
      assert.equal(await page.locator('[data-pipeline-job]').nth(1).isVisible(), false, 'only selected job should be displayed');
      assert.equal(await page.evaluate(() => window.scrollY), 180, 'polling reset page reading position');
    }
    assert.equal(navigations, 1, 'polling navigated the document');
    assert.equal(await page.evaluate(() => window.originalLog === document.querySelector('.pipeline-logs')), true, 'polling replaced the logs element');
    assert.equal(await page.evaluate(() => window.logExecuted), undefined);
    await page.locator('[data-job-select]').nth(1).click();
    await page.waitForResponse(response => response.url() === base + route + '/updates');
    assert.equal(await page.locator('[data-pipeline-job]').nth(0).isVisible(), false);
    assert.equal(await logs.nth(1).isVisible(), true);
    await page.locator('[data-job-select]').nth(0).click();
    await logs.nth(0).locator('[data-log-follow]').check();
    const following = `follow tail ${width}\n`.repeat(20);
    await api(active.endpoint + '/logs', active.token, { sequence: String(++active.sequence), step_id: 'check', stream: 'stdout', text: following });
    await page.waitForFunction(text => document.querySelector('.pipeline-logs pre').textContent.includes(text), following);
    assert.ok(await logs.nth(0).locator('pre').evaluate(e => e.getBoundingClientRect().bottom - innerHeight <= 40), 'tail following lost the bottom');
    await page.screenshot({ path: path.join(output, `logs-${width}.png`), fullPage: true });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth), false);
    if (width === 390) {
      await api(active.endpoint + '/steps', active.token, { step_id: 'check', state: 'success', exit_code: 0 });
      await api(active.endpoint + '/complete', active.token, { conclusion: 'success', last_log_sequence: String(active.sequence) });
      await page.waitForFunction(() => document.querySelector('.pipeline-logs').dataset.logComplete === 'true');
      await logs.nth(0).getByRole('button', { name: /^Show .*hidden lines/ }).waitFor();
      assert.ok((await logs.nth(0).locator('pre').textContent()).includes('preview log line 0'));
      assert.ok(!(await logs.nth(0).locator('pre').textContent()).includes('preview log line 80'));
      await logs.nth(0).getByRole('button', { name: /^Show .*hidden lines/ }).click();
      assert.ok((await logs.nth(0).locator('pre').textContent()).includes('preview log line 80'));
      const count = requests.filter(url => url.includes(active.endpoint + '/logs')).length;
      for (let n = 0; n < 2; n++) await page.waitForResponse(response => response.url() === base + route + '/updates');
      assert.equal(requests.filter(url => url.includes(active.endpoint + '/logs')).length, count, 'completed job kept polling while another job ran');

      // Pause the tab, finish a job with more than one page of output, then resume.
      await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, get: () => true }); document.dispatchEvent(new Event('visibilitychange')); });
      const pausedCount = requests.length;
      await page.waitForTimeout(2200);
      assert.equal(requests.length, pausedCount, 'hidden page kept polling');
      const last = attempts[1];
      for (let i = 0; i < 105; i++) await api(last.endpoint + '/logs', last.token, { sequence: String(++last.sequence), step_id: 'check', stream: 'stdout', text: `backlog ${i}\n` });
      const tail = last.token.slice(0, 6);
      await api(last.endpoint + '/logs', last.token, { sequence: String(++last.sequence), step_id: 'check', stream: 'stdout', text: `EOF:${tail}` });
      await api(last.endpoint + '/steps', last.token, { step_id: 'check', state: 'success', exit_code: 0 });
      await api(last.endpoint + '/complete', last.token, { conclusion: 'success', last_log_sequence: String(last.sequence) });
      await page.evaluate(() => { delete document.hidden; document.dispatchEvent(new Event('visibilitychange')); });
      await page.waitForFunction(() => document.querySelector('[data-pipeline-run]').dataset.polling === 'stopped');
      await page.locator('[data-job-select]').nth(1).click();
      await logs.nth(1).getByRole('button', { name: /^Show .*hidden lines/ }).click();
      const content = await logs.nth(1).locator('pre').textContent();
      assert.ok(content.includes('backlog 0\n'));
      assert.ok(content.includes('backlog 104\n'));
      assert.ok(content.endsWith(`EOF:${tail}`), 'stopped before reading the final flushed log tail');
      assert.equal(content.split('backlog 0\n').length, 2, 'duplicate chunks were appended');
      assert.equal(await logs.nth(0).locator('summary').count(), 0, 'whole-log folding should be absent');
      await page.getByRole('button', { name: 'Rerun snapshot', exact: true }).waitFor();
      assert.equal(await page.getByRole('button', { name: 'Cancel run', exact: true }).isVisible(), false);
      const stoppedCount = requests.length;
      await page.waitForTimeout(4500);
      assert.equal(requests.length, stoppedCount, 'terminal run kept polling');
      const beforeReload = requests.length;
      await page.reload();
      await page.waitForFunction(() => document.querySelector('[data-pipeline-run]').dataset.polling === 'stopped');
      assert.equal(await page.evaluate(() => window.logExecuted), undefined, 'server-rendered log markup was executed');
      assert.ok((await logs.nth(1).locator('pre').textContent()).endsWith(`EOF:${tail}`));
      assert.ok(requests.slice(beforeReload).every(url => !url.endsWith('/updates')), 'completed run unnecessarily polled status');
      const drainedCount = requests.length;
      await page.waitForTimeout(2500);
      assert.equal(requests.length, drainedCount, 'completed run backlog restarted polling');

      const next = await dispatch(page);
      assert.notEqual(next, route);
      const updatesUrl = base + next + '/updates';
      await page.route(updatesUrl, request => request.fulfill({ status: 503, body: 'Unavailable' }));
      await page.waitForFunction(() => document.querySelector('[data-pipeline-run]').dataset.polling === 'retrying');
      await page.unroute(updatesUrl);
      await page.waitForFunction(() => document.querySelector('[data-update-error]').hidden);
      await page.route(updatesUrl, request => request.fulfill({ status: 403, body: 'Forbidden' }));
      await page.waitForFunction(() => document.querySelector('[data-pipeline-run]').dataset.polling === 'stopped');
      await page.unroute(updatesUrl);
      await page.getByRole('button', { name: 'Cancel run', exact: true }).click();
      await page.waitForFunction(() => document.querySelector('[data-pipeline-run]').dataset.polling === 'stopped');
      assert.equal(await logs.nth(0).locator('summary').count(), 0);
    }
    await ctx.close();
  }
  assert.deepEqual(errors, []);
  if (process.env.MOONHUB_KEEP_PREVIEW === '1') {
    fs.writeFileSync(path.join(output, 'preview.json'), JSON.stringify({ base, run: base + route, pid: server.pid, directory: temp, username: 'root', passwordFile: path.join(temp, 'password') }, null, 2), { mode: 0o600 });
    keep = true;
    server.unref();
    console.log(`Pipeline log preview retained: ${base}${route}; login details: ${path.join(output, 'preview.json')}`);
  }
  console.log('Pipeline log browser tests passed: incremental output without navigation, preserved DOM/scroll/expansion, tail following, per-job stop, terminal backlog and final tail draining, zero polling after completion, hidden-tab pause, retry and access failure.');
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
