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
const output = path.join(root, '_build/merge-checks-smoke');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-merge-checks-'));
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/moonhub.exe');
const database = path.join(temp, 'moonhub.db');
const env = { ...process.env, DB_PATH: database, MAIL_OUTBOX_DIR: path.join(temp, 'mail') };
const password = randomBytes(24).toString('hex');
const provider = randomBytes(32).toString('hex');
let server, browser, base, cookie, port;
const pageErrors = [];
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function until(f, message) {
  for (let i = 0; i < 150; i++) {
    const result = await f();
    if (result) return result;
    await delay(100);
  }
  throw new Error(message);
}

function query(sql, ...params) {
  const db = new DatabaseSync(database, { readOnly: true, timeout: 5000 });
  try { return db.prepare(sql).all(...params); } finally { db.close(); }
}

async function startServer() {
  const log = fs.openSync(path.join(output, 'server.log'), 'a', 0o600);
  server = spawn(binary, [path.join(temp, 'repos'), '--assets', path.join(root, 'assets'),
    '--host', '127.0.0.1', '--port', String(port), '--root-user', 'root',
    '--root-password-file', path.join(temp, 'password')], {
    cwd: temp, env, stdio: ['ignore', log, log],
  });
  fs.closeSync(log);
  await until(async () => {
    if (server.exitCode !== null) throw new Error(fs.readFileSync(path.join(output, 'server.log'), 'utf8'));
    try { return (await fetch(base + '/-/login')).ok; } catch { return false; }
  }, 'server did not start');
}

async function stopServer() {
  if (!server || server.exitCode !== null) return;
  const child = server;
  const stopped = once(child, 'exit');
  const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
  child.kill('SIGTERM');
  try { await stopped; } finally { clearTimeout(timer); server = null; }
}

async function form(route, fields, expected = 303) {
  const response = await fetch(base + route, { method: 'POST', redirect: 'manual',
    headers: cookie ? { Cookie: cookie } : {}, body: new URLSearchParams(fields),
    signal: AbortSignal.timeout(10000) });
  if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
  const text = await response.text();
  assert.equal(response.status, expected, text);
}

async function api(route, token, fields) {
  const response = await fetch(base + '/-/runner-api/v1' + route, { method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ version: 1, ...fields }), signal: AbortSignal.timeout(10000) });
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  return body;
}

async function executeCheck(expected) {
  const token = randomBytes(32).toString('hex');
  const { assignment } = await api('/claims', provider, { request_id: randomBytes(16).toString('hex'), attempt_token: token });
  assert.ok(assignment, 'no queued check');
  const directory = path.join(temp, 'attempt-' + assignment.attempt_id);
  fs.mkdirSync(directory);
  const workspace = path.join(directory, 'workspace');
  fs.mkdirSync(workspace);
  const assignmentFile = path.join(directory, 'assignment.json');
  fs.writeFileSync(assignmentFile, JSON.stringify(assignment), { mode: 0o600 });
  // Only this script's trusted fixture runs locally, never user repositories.
  const runner = spawn(binary, ['runner', '--server', base, '--assignment', assignmentFile,
    '--workspace', workspace, '--launcher', path.join(temp, 'step-launcher'),
    '--allow-http', '--unsafe-local'], { cwd: temp, env, stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '', stderr = '';
  runner.stdout.on('data', chunk => { stdout += chunk; });
  runner.stderr.on('data', chunk => { stderr += chunk; });
  runner.stdin.end(token + '\n');
  const timer = setTimeout(() => runner.kill('SIGKILL'), 30000);
  let code;
  try { [code] = await once(runner, 'close'); } finally { clearTimeout(timer); }
  assert.equal(code, expected === 'success' ? 0 : 1, stdout + stderr);
  const report = JSON.parse(stdout.trim());
  assert.equal(report.reported, true, stdout);
  assert.equal(report.conclusion, expected, stdout);
  assert.equal(assignment.version, 2);
  assert.equal(assignment.job.steps[0].uses, 'actions/checkout@v4');
  assert.equal(report.steps[0].state, 'success');
  const run = query('SELECT * FROM pipeline_run WHERE id = ?', Number(assignment.run_id))[0];
  const context = JSON.parse(run.context_json);
  assert.equal(context.repository, 'root/demo');
  assert.equal(context.sha, run.commit_sha);
  assert.equal(context.event_name, 'pull_request');
  assert.equal(context.head_ref, 'feature');
  assert.equal(context.base_ref, 'main');
  const step = assignment.job.steps[1];
  assert.equal(step.env.TESTED_SHA, context.sha);
  assert.equal(step.env.SOURCE_BRANCH, context.head_ref);
  return run;
}

async function main() {
  fs.mkdirSync(output, { recursive: true });
  fs.mkdirSync(path.join(temp, 'repos'));
  fs.cpSync(path.join(root, 'db'), path.join(temp, 'db'), { recursive: true });
  fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  execFileSync('cc', ['-std=c11', '-Wall', '-Wextra', '-Werror', path.join(root, 'runner/step-launcher.c'), '-o', path.join(temp, 'step-launcher')]);
  const listener = net.createServer();
  await new Promise((resolve, reject) => { listener.once('error', reject); listener.listen(0, '127.0.0.1', resolve); });
  port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  base = `http://127.0.0.1:${port}`;
  await startServer();
  await form('/-/login', { name_key: 'root', password });
  await form('/-/change-password', { new_password: password, confirm_password: password });
  const cli = args => execFileSync(binary, args, { cwd: temp, env, stdio: 'pipe' });
  cli(['repo-create', 'root/demo']);
  const git = (args, input) => execFileSync('git', ['--git-dir=' + path.join(temp, 'repos/root/demo.git'),
    '-c', 'user.name=Check fixture', '-c', 'user.email=fixture@example.invalid', ...args], { input, encoding: 'utf8' }).trim();
  const workflow = ['name: MR checks acceptance', 'on: {pull_request: {types: [opened, synchronize, reopened]}}',
    'env:', '  TESTED_SHA: ${{ github.sha }}', '  SOURCE_BRANCH: ${{ github.head_ref }}',
    '  TARGET_BRANCH: ${{ github.base_ref }}', '  EVENT_NAME: ${{ github.event_name }}', '  REPOSITORY: ${{ github.repository }}',
    'jobs:', '  check:',
    '    runs-on: [self-hosted, linux]', '    steps:', '      - uses: actions/checkout@v4', '      - id: check', '        run: |',
    '          test -f target-only.txt', '          test "$TESTED_SHA" = "$GITHUB_SHA"',
    '          test "$SOURCE_BRANCH" = feature', '          test "$TARGET_BRANCH" = main',
    '          test "$EVENT_NAME" = pull_request', '          test "$REPOSITORY" = root/demo',
    '          grep -q PASS README.md', '          echo verified-merged-tree', ''].join('\n');
  const blob = text => git(['hash-object', '-w', '--stdin'], text);
  const tree = entries => git(['mktree'], entries.join('\n') + '\n');
  const workflowTree = tree([`100644 blob ${blob(workflow)}\tbuild.yml`]);
  const githubTree = tree([`040000 tree ${workflowTree}\tworkflows`]);
  const baseTree = tree([`040000 tree ${githubTree}\t.github`]);
  const ancestor = git(['commit-tree', baseTree, '-m', 'Target policy']);
  const targetTree = tree([`040000 tree ${githubTree}\t.github`, `100644 blob ${blob('only on target\n')}\ttarget-only.txt`]);
  const target = git(['commit-tree', targetTree, '-p', ancestor, '-m', 'Target advanced']);
  git(['update-ref', 'refs/heads/main', target]);
  const featureTree = tree([`100644 blob ${blob('PASS\n')}\tREADME.md`]);
  let source = git(['commit-tree', featureTree, '-p', ancestor, '-m', 'Source removes workflow']);
  git(['update-ref', 'refs/heads/feature', source]);
  const tokenFile = path.join(temp, 'provider');
  fs.writeFileSync(tokenFile, provider, { mode: 0o600 });
  cli(['pipeline-provider-create', '--name', 'mr-checks', '--token-file', tokenFile, '--repositories', 'root/demo']);
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const split = cookie.indexOf('=');
  await context.addCookies([{ name: cookie.slice(0, split), value: cookie.slice(split + 1), url: base }]);
  const page = await context.newPage();
  page.setDefaultTimeout(10000);
  page.on('pageerror', error => pageErrors.push(error.message));
  await page.goto(base + '/root/demo/settings/branches');
  await page.getByLabel('Branch name', { exact: true }).fill('main');
  await page.getByLabel('Required approvals', { exact: true }).selectOption('0');
  await page.getByLabel('Required workflows (one path per line)', { exact: true }).fill('.github/workflows/build.yml');
  await page.getByRole('button', { name: 'Protect branch', exact: true }).click();
  await page.waitForURL('**/settings/branches');
  await page.goto(base + '/root/demo/merge-requests/new');
  await page.getByLabel('Source branch', { exact: true }).selectOption('feature');
  await page.getByLabel('Target branch', { exact: true }).selectOption('main');
  await page.getByLabel('Title', { exact: true }).fill('Verify merged source before merge');
  await page.getByRole('button', { name: 'Create merge request', exact: true }).click();
  await page.waitForURL('**/merge-requests/1');
  await until(() => query('SELECT id FROM pipeline_run').length === 1, 'first check was not queued');
  await stopServer();
  await startServer();
  const first = await executeCheck('success');
  assert.equal(first.workflow_source, workflow);
  assert.equal(git(['show', '-s', '--format=%P', first.commit_sha]), target + ' ' + source);
  assert.equal(query('SELECT COUNT(*) AS n FROM pipeline_run')[0].n, 1, 'restart duplicated a check');
  await page.reload();
  assert.equal(await page.getByRole('button', { name: 'Merge request', exact: true }).count(), 1);
  const old = source;
  const failingTree = tree([`100644 blob ${blob('FAIL\n')}\tREADME.md`]);
  source = git(['commit-tree', failingTree, '-p', old, '-m', 'Fail required check']);
  git(['update-ref', 'refs/heads/feature', source]);
  await page.reload();
  assert.equal(await page.getByRole('button', { name: 'Merge request', exact: true }).count(), 0);
  await page.getByRole('button', { name: 'Approve and run checks', exact: true }).click();
  await until(() => query('SELECT id FROM pipeline_run').length === 2, 'updated check was not queued');
  const failed = await executeCheck('failure');
  await page.reload();
  const mrToken = await page.locator('form input[name=csrf_token]').first().inputValue();
  await form('/root/demo/merge-requests/1/merge', { csrf_token: mrToken, version: '2' }, 400);
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 1000 });
    if (width === 390) {
      await page.waitForFunction(() => {
        const sidebar = document.querySelector('#app-sidebar');
        return sidebar.inert && getComputedStyle(sidebar).visibility === 'hidden' && sidebar.getBoundingClientRect().right <= 1;
      });
      await page.getByRole('button', { name: 'Open navigation', exact: true }).click();
      await page.waitForFunction(() => document.querySelector('#app-sidebar').getBoundingClientRect().left >= 0);
      assert.equal(await page.locator('#main-content').evaluate(element => element.inert), true);
      await page.locator('#app-sidebar').getByRole('button', { name: 'Close navigation', exact: true }).click();
      await page.waitForFunction(() => getComputedStyle(document.querySelector('#app-sidebar')).visibility === 'hidden');
      assert.equal(await page.locator('#main-content').evaluate(element => element.inert), false);
    }
    await page.screenshot({ path: path.join(output, `checks-failed-${width}.png`), fullPage: true, animations: 'disabled' });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth), false);
  }
  await page.getByRole('link', { name: `Run #${failed.number} and logs`, exact: true }).click();
  assert.equal(await page.getByRole('link', { name: 'Merge request !1, version 2', exact: true }).count(), 1);
  await page.getByRole('button', { name: 'Rerun snapshot', exact: true }).click();
  await until(() => query('SELECT id FROM pipeline_run').length === 3, 'rerun not created');
  await executeCheck('failure');
  const fixed = git(['commit-tree', featureTree, '-p', source, '-m', 'Fix required check']);
  git(['update-ref', 'refs/heads/feature', fixed]);
  await page.goto(base + '/root/demo/merge-requests/1');
  await page.getByRole('button', { name: 'Approve and run checks', exact: true }).click();
  await until(() => query('SELECT id FROM pipeline_run').length === 4, 'fixed check not queued');
  await executeCheck('success');
  await page.reload();
  await page.getByRole('button', { name: 'Merge request', exact: true }).click();
  await until(() => query('SELECT status FROM merge_request')[0].status === 'merged', 'merge did not finish');
  assert.equal(git(['rev-parse', 'main^{tree}']), git(['rev-parse', query('SELECT commit_sha FROM pipeline_run WHERE number = 4')[0].commit_sha + '^{tree}']));
  assert.deepEqual(pageErrors, []);
  const receipt = { checks: ['pull_request workflow', 'built-in checkout', 'immutable run context', 'env field references', 'target-owned workflow', 'merged-tree execution', 'restart deduplication', 'stale success rejected',
    'failure blocks merge', 'snapshot rerun', 'desktop/mobile layout', 'successful gated merge'], runs: 4 };
  fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
  console.log(JSON.stringify(receipt));
}

main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close();
  await stopServer();
  fs.rmSync(temp, { recursive: true, force: true });
});
