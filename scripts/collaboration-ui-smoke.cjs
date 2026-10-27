// Disposable service/actors/repository. Exercises actual forms, authorization and UI.
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
const output = path.join(root, '_build/collaboration-ui');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-ui-'));
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/moonhub.exe');
const password = randomBytes(24).toString('hex');
const env = { ...process.env, DB_PATH: path.join(temp, 'moonhub.db'), MAIL_OUTBOX_DIR: path.join(temp, 'mail') };
let server, browser, base, cookie, keep = false;
const errors = [];
const csrf = html => html.match(/name="csrf_token" value="([^"]+)"/)[1];
async function form(route, fields, expected = 303) {
  const response = await fetch(base + route, { method: 'POST', redirect: 'manual', headers: cookie ? { Cookie: cookie } : {}, body: new URLSearchParams(fields) });
  if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
  const body = await response.text(); assert.equal(response.status, expected, body); return body;
}
async function runner(route, token, fields) {
  const response = await fetch(base + '/-/runner-api/v1' + route, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ version: 1, ...fields }) });
  const body = await response.json(); assert.equal(response.status, 200, JSON.stringify(body)); return body;
}
async function context(session, options = {}) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1000 }, ...options });
  const at = session.indexOf('='); await ctx.addCookies([{ name: session.slice(0, at), value: session.slice(at + 1), url: base }]);
  ctx.on('page', page => { page.setDefaultTimeout(10000); page.on('pageerror', error => errors.push(error.message)); }); return ctx;
}
async function shot(page, name, width = 1440) {
  await page.setViewportSize({ width, height: width === 390 ? 844 : 1000 });
  await page.waitForFunction(() => document.documentElement.scrollWidth <= innerWidth && (innerWidth > 900 || document.querySelector('#app-sidebar').getBoundingClientRect().right <= 1));
  await page.evaluate(async () => { document.activeElement?.blur(); window.scrollTo(0, 0); await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))); });
  await page.screenshot({ path: path.join(output, name + '.png'), fullPage: true });
}
async function main() {
  fs.mkdirSync(output, { recursive: true }); fs.mkdirSync(path.join(temp, 'repos'));
  fs.cpSync(path.join(root, 'db'), path.join(temp, 'db'), { recursive: true }); fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  const listener = net.createServer(); await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve)); const port = listener.address().port; await new Promise(resolve => listener.close(resolve)); base = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(output, 'server.log'), 'w', 0o600);
  server = spawn(binary, [path.join(temp, 'repos'), '--assets', path.join(root, 'assets'), '--host', '127.0.0.1', '--port', String(port), '--root-user', 'root', '--root-password-file', path.join(temp, 'password')], { cwd: temp, env, stdio: ['ignore', log, log] }); fs.closeSync(log);
  for (let i = 0; i < 150; i++) { if (server.exitCode !== null) throw new Error(fs.readFileSync(path.join(output, 'server.log'), 'utf8')); try { if ((await fetch(base + '/-/login')).ok) break; } catch {} await new Promise(resolve => setTimeout(resolve, 100)); }
  await form('/-/login', { name_key: 'root', password }); await form('/-/change-password', { new_password: password, confirm_password: password });
  const rootCookie = cookie;
  const cli = args => execFileSync(binary, args, { cwd: temp, env, stdio: 'pipe' }); cli(['repo-create', 'root/demo']);
  const db = new DatabaseSync(env.DB_PATH);
  db.exec(`INSERT INTO "user"(name_key,display_name,password_hash) SELECT 'reviewer','Reviewer',password_hash FROM "user" WHERE name_key='root'; INSERT INTO team_member(team_id,user_id,role) SELECT t.id,u.id,'member' FROM team t JOIN "user" u WHERE t.name_key='root' AND u.name_key='reviewer';`); db.close();
  const git = (args, input) => execFileSync('git', ['--git-dir=' + path.join(temp, 'repos/root/demo.git'), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', ...args], { input, encoding: 'utf8' }).trim();
  const blob = text => git(['hash-object', '-w', '--stdin'], text);
  const tree = lines => git(['mktree'], lines.join('\n') + '\n');
  const workflow = 'name: Verify collaboration\non: workflow_dispatch\njobs:\n  build:\n    runs-on: self-hosted\n    steps:\n      - id: check\n        run: echo fixture\n  lint:\n    runs-on: self-hosted\n    steps:\n      - id: check\n        run: echo lint\n';
  const workflows = tree([`100644 blob ${blob(workflow)}\tverify.yml`]); const github = tree([`040000 tree ${workflows}\tworkflows`]);
  const baseTree = tree([`040000 tree ${github}\t.github`, `100644 blob ${blob('base\n')}\tREADME.md`, `100644 blob ${blob('let x = 1\n')}\tmain.mbt`]);
  const initial = git(['commit-tree', baseTree, '-m', 'Initial']); git(['update-ref', 'refs/heads/main', initial]);
  const featureTree = tree([`040000 tree ${github}\t.github`, `100644 blob ${blob('feature\n')}\tREADME.md`, `100644 blob ${blob('let x = 2\n')}\tmain.mbt`]);
  const feature = git(['commit-tree', featureTree, '-p', initial, '-m', 'Feature']); git(['update-ref', 'refs/heads/feature', feature]);
  const provider = randomBytes(32).toString('hex'); fs.writeFileSync(path.join(temp, 'provider'), provider, { mode: 0o600 }); cli(['pipeline-provider-create', '--name', 'fixture', '--token-file', path.join(temp, 'provider'), '--repositories', 'root/demo']);
  browser = await chromium.launch({ headless: true });
  const rootContext = await context(rootCookie), page = await rootContext.newPage();
  await page.goto(base + '/root/demo/pipelines');
  assert.equal(await page.getByRole('navigation', { name: 'Pipeline views' }).getByRole('link').count(), 3);
  assert.equal(await page.getByText('Automatic workflows', { exact: true }).count(), 0);
  await page.getByRole('link', { name: 'Settings', exact: true }).click(); await page.getByLabel('Run push workflows').check(); await page.getByRole('button', { name: 'Save settings' }).click(); await page.getByRole('status').filter({ hasText: 'Pipeline settings saved' }).waitFor();
  await shot(page, 'pipeline-settings-desktop');
  await page.goto(base + '/root/demo/pipelines/new');
  fs.writeFileSync(path.join(output, 'dispatch.html'), await page.content());
  assert.equal(await page.getByLabel('Branch', { exact: true }).inputValue(), 'main');
  assert.equal(await page.getByLabel('Workflow', { exact: true }).inputValue(), '.github/workflows/verify.yml');
  await shot(page, 'pipeline-run-desktop'); await page.getByRole('button', { name: 'Run workflow', exact: true }).click(); await page.waitForURL(/\/pipelines\/\d+$/);
  const runRoute = new URL(page.url()).pathname;
  const attemptToken = randomBytes(32).toString('hex'); const { assignment } = await runner('/claims', provider, { request_id: randomBytes(16).toString('hex'), attempt_token: attemptToken }); assert.ok(assignment);
  const endpoint = '/attempts/' + assignment.attempt_id;
  await runner(endpoint + '/start', attemptToken, { execution_id: randomBytes(16).toString('hex') }); await runner(endpoint + '/steps', attemptToken, { step_id: 'check', state: 'running', exit_code: 0 });
  await runner(endpoint + '/logs', attemptToken, { sequence: '1', step_id: 'check', stream: 'stdout', text: Array.from({ length: 240 }, (_, i) => `setup line ${i}\n`).join('') });
  await page.reload(); await page.waitForSelector('[data-log-search]');
  assert.equal(await page.locator('[data-step-exit]').first().isVisible(), false, 'running step implied exit 0');
  const pre = page.locator('.pipeline-logs pre').first(); await page.evaluate(() => window.scrollTo(0, 80));
  await runner(endpoint + '/logs', attemptToken, { sequence: '2', step_id: 'check', stream: 'stderr', text: 'ERROR: collaboration fixture failed\n<script>window.logExecuted=true</script>\n' });
  await page.waitForFunction(() => document.querySelector('.pipeline-logs pre').textContent.includes('fixture failed'));
  assert.equal(await page.evaluate(() => window.scrollY), 80, 'live update moved the reader');
  assert.ok(await pre.evaluate(e => e.scrollHeight <= e.clientHeight + 1), 'log must not have nested vertical scrolling');
  await runner(endpoint + '/steps', attemptToken, { step_id: 'check', state: 'failure', exit_code: 1 }); await runner(endpoint + '/complete', attemptToken, { conclusion: 'failure', last_log_sequence: '2' });
  await page.reload(); await page.getByRole('button', { name: /^Show .*hidden lines/ }).first().waitFor();
  assert.ok(!(await pre.textContent()).includes('setup line 80'));
  await shot(page, 'pipeline-log-desktop'); await shot(page, 'pipeline-log-mobile', 390);
  await page.getByRole('button', { name: /^Show .*hidden lines/ }).first().click(); assert.ok((await pre.textContent()).includes('setup line 80'));
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.getByRole('button', { name: 'Find error output', exact: true }).first().click(); await page.locator('mark[data-current]').first().waitFor();
  assert.ok(await page.evaluate(() => window.scrollY > 0), 'failure match remained out of view');
  assert.equal(await page.evaluate(() => window.logExecuted), undefined); await page.screenshot({ path: path.join(output, 'pipeline-error-desktop.png') });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForFunction(() => document.querySelector('#app-sidebar').getBoundingClientRect().right <= 1);
  await page.waitForFunction(() => { const box = document.querySelector('mark[data-current]').getBoundingClientRect(); return box.top >= 0 && box.bottom <= innerHeight; });
  assert.ok(await page.locator('mark[data-current]').first().evaluate(mark => {
    const box = mark.getBoundingClientRect();
    return box.top >= 0 && box.bottom <= innerHeight;
  }), 'selected search match must remain visible after mobile resize');
  await page.screenshot({ path: path.join(output, 'pipeline-error-mobile.png') });
  const eventDb = new DatabaseSync(env.DB_PATH);
  eventDb.exec('PRAGMA busy_timeout=5000');
  const event = eventDb.prepare("INSERT INTO repository_ref_event(repository_id,actor_id,source_key,reference,old_sha,new_sha,state,last_error) SELECT id,1,'fixture-event','refs/heads/main','',?,'processed','other.yml: unsupported fixture syntax' FROM repository WHERE name='demo' RETURNING id").get(initial);
  eventDb.prepare("INSERT INTO pipeline_run(repository_id,number,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,source_ref,definition_version,workflow_source,definition_json,trigger_event_id) SELECT repository_id,2,requested_by_user_id,workflow_path,workflow_name,source_branch,commit_sha,'refs/moonhub/pipelines/fixture-trigger',definition_version,workflow_source,definition_json,? FROM pipeline_run WHERE number=1").run(event.id); eventDb.close();
  await page.goto(base + '/root/demo/pipelines?tab=events'); await page.getByRole('link', { name: '#2 · Verify collaboration', exact: true }).waitFor();
  await shot(page, 'pipeline-events-desktop'); await shot(page, 'pipeline-events-mobile', 390); await page.setViewportSize({ width: 1440, height: 1000 });
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(base + '/root/demo/merge-requests/new');
  assert.equal(await page.getByLabel('Target branch').inputValue(), 'main');
  assert.equal(await page.getByLabel('Source branch').inputValue(), 'feature');
  await page.getByLabel('Source branch').selectOption('main'); assert.equal(await page.getByText('Source and target must be different branches.').isVisible(), true); await page.getByLabel('Source branch').selectOption('feature');
  await page.getByLabel('Title', { exact: true }).fill('Improve collaboration workspaces');
  const markdown = '# What changes\n\n**Clear status** and `version-bound` actions.\n\n- Pipeline navigation\n- Review workspace\n\n```mbt\nlet safe = "<script>"\n```\n\n[Safe link](https://example.invalid)\n[Unsafe link](javascript:alert)\n<img src=x onerror="window.markdownExecuted=true">';
  await page.getByLabel('Description', { exact: true }).fill(markdown); await page.getByRole('button', { name: 'Create merge request', exact: true }).click(); await page.waitForURL(/\/merge-requests\/\d+$/);
  const mrRoute = new URL(page.url()).pathname;
  await page.getByRole('heading', { name: 'What changes' }).waitFor(); assert.equal(await page.locator('.markdown-body img').count(), 0); assert.equal(await page.locator('.markdown-body a[href^="javascript:"]').count(), 0);
  assert.equal(await page.evaluate(() => window.markdownExecuted), undefined);
  assert.equal(await page.getByText('You authored this merge request and cannot approve it yourself.', { exact: false }).isVisible(), true);
  const mergeTop = await page.getByRole('region', { name: 'Merge status' }).evaluate(e => e.getBoundingClientRect().top); assert.ok(mergeTop < 1000, 'merge readiness below first viewport');
  const next = git(['commit-tree', featureTree, '-p', feature, '-m', 'Next version']); git(['update-ref', 'refs/heads/feature', next]); await page.reload(); assert.equal(await page.getByLabel('Version', { exact: true }).inputValue(), '2');
  await page.getByText('Write a comment or review', { exact: true }).click(); await page.getByLabel('Comment', { exact: true }).fill('Unsent review draft');
  await page.getByRole('link', { name: 'Changes', exact: true }).click(); await page.locator('.diff-file-nav button').first().waitFor(); assert.equal(await page.locator('.diff-file-nav button').count(), 2);
  await page.getByText('Write a comment or review', { exact: true }).click(); assert.equal(await page.getByLabel('Comment', { exact: true }).inputValue(), 'Unsent review draft');
  await page.getByLabel('Version', { exact: true }).selectOption('1'); await page.waitForURL(/tab=changes.*version=1/); assert.equal(await page.getByText('Viewing an older version. Reviews apply only to the latest version.').isVisible(), true); assert.equal(await page.getByRole('button', { name: 'Submit review', exact: true }).count(), 0);
  await page.getByLabel('Version', { exact: true }).selectOption('2'); await page.waitForURL(/tab=changes.*version=2/);
  await page.getByLabel('Diff view').selectOption('unified'); await page.locator('.diff-file-nav button').last().click(); await shot(page, 'mr-diff-desktop'); await shot(page, 'mr-diff-mobile', 390);
  await page.setViewportSize({ width: 1440, height: 1000 }); await page.goto(base + mrRoute); await shot(page, 'mr-desktop'); await shot(page, 'mr-mobile', 390); await page.setViewportSize({ width: 1440, height: 1000 });
  await page.waitForFunction(() => document.querySelector('.mr-reviewers').open);
  await page.getByRole('combobox', { name: 'Request a reviewer' }).selectOption('2'); await page.getByRole('button', { name: 'Request review', exact: true }).click();
  cookie = undefined; await form('/-/login', { name_key: 'reviewer', password }); const reviewerCookie = cookie; const reviewerContext = await context(reviewerCookie), reviewerPage = await reviewerContext.newPage();
  const deniedSettings = await reviewerPage.goto(base + '/root/demo/pipelines?tab=settings'); assert.equal(deniedSettings.status(), 403);
  await reviewerPage.goto(base + mrRoute); await reviewerPage.getByText('Write a comment or review', { exact: true }).click(); assert.equal(await reviewerPage.getByRole('option', { name: 'Approve', exact: true }).count(), 1);
  await reviewerPage.getByRole('combobox', { name: 'Review', exact: true }).selectOption('approved'); await reviewerPage.getByRole('button', { name: 'Submit review', exact: true }).click();
  cookie = rootCookie; const mrHtml = await (await fetch(base + mrRoute, { headers: { Cookie: cookie } })).text(); await form(mrRoute + '/close', { csrf_token: csrf(mrHtml), version: '2', edit_version: '1' });
  await reviewerPage.goto(base + '/-/notifications'); assert.equal(await reviewerPage.locator('.inbox-list > li').count(), 1); assert.equal(await reviewerPage.getByText('Historical updates · this merge request is closed.').isVisible(), true); await shot(reviewerPage, 'inbox-desktop'); await shot(reviewerPage, 'inbox-mobile', 390);
  await reviewerPage.getByRole('button', { name: 'Mark read', exact: true }).click(); await reviewerPage.getByRole('heading', { name: "You're caught up" }).waitFor();
  await page.goto(base + '/root/demo/issues/new'); await page.getByLabel('Title', { exact: true }).fill('Track the collaboration flow'); await page.getByLabel('Description', { exact: true }).fill(markdown); await page.getByRole('button', { name: 'Create issue', exact: true }).click(); await page.waitForURL(/\/issues\/\d+$/); await page.getByRole('heading', { name: 'What changes' }).waitFor(); await page.goto(base + '/root/demo/issues'); await shot(page, 'issues-desktop'); await shot(page, 'issues-mobile', 390);
  await page.setViewportSize({ width: 1440, height: 1000 }); await page.goto(base + '/root/demo/pipelines'); await shot(page, 'pipelines-desktop'); await shot(page, 'pipelines-mobile', 390);
  const noScript = await context(rootCookie, { javaScriptEnabled: false }), nativePage = await noScript.newPage(); await nativePage.goto(base + mrRoute + '?version=1'); assert.equal(await nativePage.getByRole('button', { name: 'View', exact: true }).isVisible(), true); await nativePage.getByLabel('Version', { exact: true }).selectOption('2'); await nativePage.getByRole('button', { name: 'View', exact: true }).click(); await nativePage.waitForURL(/version=2/);
  assert.deepEqual(errors, []);
  fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({ status: 'passed', cases: ['Pipeline tabs, trigger run links and settings permissions', 'real dispatch choices', 'live log scroll, completed middle expansion and search safety', 'MR branch prevention and version dropdown', 'version-scoped draft recovery', 'safe Markdown', 'diff navigation and responsive mode', 'grouped current-state inbox and read boundary', 'Issue content and lists', 'no-script version navigation'], screenshots: 18 }, null, 2));
  if (process.env.MOONHUB_KEEP_PREVIEW === '1') { fs.writeFileSync(path.join(output, 'preview.json'), JSON.stringify({ base, mr: mrRoute, run: runRoute, pid: server.pid, directory: temp, username: 'root', passwordFile: path.join(temp, 'password') }, null, 2), { mode: 0o600 }); server.unref(); keep = true; }
  console.log('Collaboration UI acceptance passed.');
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => { await browser?.close(); if (!keep && server && server.exitCode === null) { const ended = once(server, 'exit'); server.kill('SIGTERM'); await ended; } if (!keep) fs.rmSync(temp, { recursive: true, force: true }); });
