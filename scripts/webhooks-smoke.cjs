// Disposable end-to-end fixture. Never connects to a user's instance.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { randomBytes, createHmac } = require('node:crypto');
const { execFileSync, spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const { DatabaseSync } = require('node:sqlite');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '..');
const output = path.join(root, '_build/webhooks-smoke');
const review = path.join(root, '.impeccable/review/webhooks');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-webhooks-'));
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/moonhub.exe');
const database = path.join(temp, 'moonhub.db');
const password = randomBytes(24).toString('hex');
const secret = randomBytes(32).toString('hex');
let server, browser, receiver;
const seen = [];
let receiverStatus = 204;
let receiverEarlyHints = true;
const env = { ...process.env, DB_PATH: database, MAIL_OUTBOX_DIR: path.join(temp, 'mail') };
async function until(f, message) {
  for (let i = 0; i < 150; i++) { const r = await f(); if (r) return r; await new Promise(r => setTimeout(r, 100)); }
  throw new Error(message);
}
function sql(statement, ...params) {
  const db = new DatabaseSync(database, { timeout: 5000 });
  try { return db.prepare(statement).all(...params); } finally { db.close(); }
}
async function main() {
  fs.mkdirSync(output, { recursive: true });
  fs.mkdirSync(review, { recursive: true });
  fs.mkdirSync(path.join(temp, 'repos'));
  fs.cpSync(path.join(root, 'db'), path.join(temp, 'db'), { recursive: true });
  fs.writeFileSync(path.join(temp, 'password'), password, { mode: 0o600 });
  receiver = http.createServer(async (req, res) => {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    assert.equal(req.headers['x-moonhub-signature-256'], 'sha256=' + createHmac('sha256', secret).update(body).digest('hex'));
    seen.push({ headers: req.headers, payload: JSON.parse(body), bytes: body.toString() });
    if (receiverEarlyHints) res.writeEarlyHints({ link: '</health.css>; rel=preload; as=style' });
    res.writeHead(receiverStatus, { 'Content-Length': '0', Location: 'http://127.0.0.1:1/private' }); res.end();
  });
  receiver.listen(0, '127.0.0.1'); await once(receiver, 'listening');
  const origin = 'http://127.0.0.1:' + receiver.address().port;
  env.MOONHUB_WEBHOOK_ALLOWED_ORIGINS = origin;
  const portServer = http.createServer(); portServer.listen(0, '127.0.0.1'); await once(portServer, 'listening');
  const port = portServer.address().port; await new Promise(r => portServer.close(r));
  const base = 'http://127.0.0.1:' + port;
  const log = fs.openSync(path.join(output, 'server.log'), 'w', 0o600);
  const start = () => spawn(binary, [path.join(temp, 'repos'), '--assets', path.join(root, 'assets'), '--host', '127.0.0.1', '--port', String(port), '--root-user', 'root', '--root-password-file', path.join(temp, 'password')], { cwd: temp, env, stdio: ['ignore', log, log] });
  server = start();
  await until(async () => { if (server.exitCode !== null) throw new Error(fs.readFileSync(path.join(output, 'server.log'), 'utf8')); try { return (await fetch(base + '/-/login')).ok; } catch { return false; } }, 'server did not start');
  let cookie;
  async function form(route, data, expected = 303) {
    const r = await fetch(base + route, { method: 'POST', body: new URLSearchParams(data), headers: cookie ? { Cookie: cookie } : {}, redirect: 'manual' });
    if (r.headers.get('set-cookie')) cookie = r.headers.get('set-cookie').split(';')[0];
    const body = await r.text(); assert.equal(r.status, expected, body); return body;
  }
  await form('/-/login', { name_key: 'root', password });
  await form('/-/change-password', { new_password: password, confirm_password: password });
  execFileSync(binary, ['repo-create', 'root/demo'], { cwd: temp, env, stdio: 'pipe' });
  const page = await (await fetch(base + '/-/settings/tokens', { headers: { Cookie: cookie } })).text();
  const csrf = page.match(/name="csrf_token" value="([^"]+)"/)[1];
  const created = await form('/-/settings/tokens', { csrf_token: csrf, name: 'Webhook smoke', permission: 'write', days: '1' }, 200);
  const token = created.match(/value="(mh_[a-f0-9]{64})"/)[1];
  const tokenFile = path.join(temp, 'webhook.token'); fs.writeFileSync(tokenFile, token, { mode: 0o600 });
  function cli(args, expected = 0) {
    const r = spawnSync(binary, [...args, '--server', base, '--allow-http', '--repo', 'root/demo', '--token-file', tokenFile, '--json'], { cwd: temp, env: { ...env, MOONHUB_TOKEN: '', MOONHUB_SERVER: '', MOONHUB_REPOSITORY: '', XDG_CONFIG_HOME: path.join(temp, 'config') }, encoding: 'utf8', timeout: 30000 });
    assert.equal(r.status, expected, r.stdout + r.stderr);
    assert.ok(!r.stdout.includes(secret)); assert.ok(!r.stdout.includes(token));
    return expected === 0 ? JSON.parse(r.stdout.trim()) : r;
  }
  const file = path.join(temp, 'hook.json');
  fs.writeFileSync(file, JSON.stringify({ url: origin + '/hooks/moonhub', secret, events: ['push', 'issue', 'merge_request', 'review', 'workflow_run'], active: true }), { mode: 0o600 });
  const hook = cli(['webhook', 'create', '--body-file', file]);
  assert.equal(cli(['webhook', 'list']).items.length, 1);
  cli(['webhook', 'ping', hook.id]);
  await until(() => seen.length === 1, 'test event missing');
  assert.equal(seen[0].payload.event, 'ping');
  await until(() => cli(['webhook', 'deliveries', hook.id]).items[0].status === 'succeeded', 'delivery not completed');
  const issue = cli(['issue', 'create', '--title', 'Webhook fixture 世界']);
  await until(() => seen.some(x => x.payload.issue?.title === issue.title), 'issue event missing');
  const issueEvent = seen.find(x => x.payload.issue?.title === issue.title);
  assert.equal(issueEvent.payload.sender.username, 'root');
  assert.equal(issueEvent.payload.repository.full_name, 'root/demo');
  // The native suite covers transaction capture; exercise recovery in the running server.
  const gitDir = path.join(temp, 'repos/root/demo.git');
  const git = (args, input) => execFileSync('git', ['--git-dir=' + gitDir, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', ...args], { input, encoding: 'utf8' }).trim();
  const tree = git(['mktree'], ''); const sha = git(['commit-tree', tree, '-m', 'Fixture']);
  git(['update-ref', 'refs/heads/main', sha]);
  // Recover a tag update left prepared by a simulated process interruption.
  const key = 'a'.repeat(32), zero = '0'.repeat(40);
  sql("INSERT INTO webhook_ref_intent(repository_id,actor_id,source_key,reference,old_sha,new_sha,state) SELECT r.id,u.id,?,'refs/tags/v1',?,?,'prepared' FROM repository r JOIN team t ON t.id=r.team_id JOIN \"user\" u ON u.name_key='root' WHERE t.name_key='root' AND r.name='demo'", key, zero, sha);
  git(['update-ref', 'refs/tags/v1', sha]);
  await until(() => seen.some(x => x.payload.ref === 'refs/tags/v1'), 'recovered tag event missing');
  // Exercise actual Git receive-pack and trusted hooks; only SSH transport is local.
  const hooks = path.join(temp, 'hooks'); fs.mkdirSync(hooks);
  for (const name of ['pre-receive', 'reference-transaction']) {
    fs.copyFileSync(path.join(root, 'deploy/hooks', name), path.join(hooks, name));
    fs.chmodSync(path.join(hooks, name), 0o700);
  }
  const userKey = execFileSync(binary, ['ssh-key-add', 'root'], { cwd: temp, env,
    input: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB\n', encoding: 'utf8' }).trim().split('\t')[0];
  const transport = path.join(temp, 'ssh');
  fs.writeFileSync(transport, '#!/bin/sh\nfor arg do SSH_ORIGINAL_COMMAND=$arg; done\nexport SSH_ORIGINAL_COMMAND\nexec "$MOONHUB_BIN" ssh-serve "$MOONHUB_TEST_KEY_ID"\n', { mode: 0o700 });
  const source = path.join(temp, 'source'); fs.mkdirSync(source);
  const pushEnv = { ...env, MOONHUB_REPO_ROOT: path.join(temp, 'repos'), MOONHUB_BIN: binary,
    MOONHUB_HOOKS_PATH: hooks, MOONHUB_TEST_KEY_ID: userKey, GIT_SSH: transport, GIT_SSH_VARIANT: 'simple' };
  const sourceGit = args => execFileSync('git', args, { cwd: source, env: pushEnv, encoding: 'utf8', timeout: 30000 }).trim();
  sourceGit(['init', '-q', '-b', 'topic']); sourceGit(['config', 'user.name', 'Webhook fixture']);
  sourceGit(['config', 'user.email', 'fixture@example.invalid']); sourceGit(['commit', '--allow-empty', '-qm', 'Real push']);
  sourceGit(['push', 'fixture:/root/demo.git', 'HEAD:refs/heads/topic', 'HEAD:refs/tags/real-tag']);
  await until(() => seen.some(x => x.payload.ref === 'refs/heads/topic') && seen.some(x => x.payload.ref === 'refs/tags/real-tag'), 'real receive hooks did not deliver');
  sourceGit(['push', 'fixture:/root/demo.git', ':refs/heads/topic', ':refs/tags/real-tag']);
  await until(() => seen.some(x => x.payload.ref === 'refs/tags/real-tag' && x.payload.action === 'deleted'), 'real tag deletion did not deliver');
  assert.equal(sql('SELECT COUNT(*) AS count FROM repository_ref_event')[0].count, 0);
  // Failed delivery survives a real server restart and is retried with identical identity/body.
  receiverEarlyHints = false;
  receiverStatus = 503;
  cli(['webhook', 'ping', hook.id]);
  await until(() => cli(['webhook', 'deliveries', hook.id]).items[0].response_code === '503', 'failed attempt missing');
  const failed = cli(['webhook', 'deliveries', hook.id]).items[0];
  const prior = seen.find(x => x.headers['x-moonhub-delivery'] === failed.id);
  server.kill('SIGTERM'); await once(server, 'exit');
  sql("UPDATE webhook_delivery SET next_attempt_at=datetime('now') WHERE id=?", failed.id);
  receiverStatus = 204;
  server = start();
  await until(async () => { try { return (await fetch(base + '/-/login')).ok; } catch { return false; } }, 'server restart failed');
  await until(() => cli(['webhook', 'deliveries', hook.id]).items[0].status === 'succeeded', 'restart retry failed');
  const retry = seen.filter(x => x.headers['x-moonhub-delivery'] === failed.id);
  assert.equal(retry.length, 2); assert.equal(retry[1].bytes, prior.bytes);
  const detail = cli(['webhook', 'delivery', hook.id, '--delivery', failed.id]);
  assert.equal(detail.attempts.length, 2);
  // Existing visual system at desktop/mobile. No JavaScript is needed for form submission.
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await context.addCookies([{ name: cookie.split('=')[0], value: cookie.slice(cookie.indexOf('=') + 1), url: base }]);
  const ui = await context.newPage(); const route = '/root/demo/settings/webhooks';
  await ui.goto(base + route + '/' + hook.id);
  await ui.getByRole('heading', { name: 'Edit webhook', exact: true }).waitFor();
  assert.equal(await ui.locator('#webhook-secret').inputValue(), '');
  await ui.screenshot({ path: path.join(review, 'desktop.png'), fullPage: true });
  await ui.setViewportSize({ width: 390, height: 844 });
  await ui.waitForFunction(() => document.querySelector('#app-sidebar').getBoundingClientRect().right <= 1);
  await ui.screenshot({ path: path.join(review, 'mobile.png'), fullPage: true });
  assert.ok(await ui.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await ui.goto(base + route + '/' + hook.id + '/deliveries');
  await ui.screenshot({ path: path.join(review, 'mobile-deliveries.png'), fullPage: true });
  assert.ok(await ui.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await ui.setViewportSize({ width: 1440, height: 1000 });
  await ui.screenshot({ path: path.join(review, 'desktop-deliveries.png'), fullPage: true });
  const nojs = await browser.newContext({ javaScriptEnabled: false });
  await nojs.addCookies(await context.cookies());
  const native = await nojs.newPage(); await native.goto(base + route + '/' + hook.id);
  await native.getByRole('button', { name: 'Save webhook', exact: true }).click();
  await native.waitForURL(base + route + '/' + hook.id);
  assert.equal(cli(['webhook', 'list']).items[0].version, '2');
  cli(['webhook', 'delete', hook.id, '--version', '1'], 1);
  cli(['webhook', 'delete', hook.id, '--version', '2']);
  assert.equal(cli(['webhook', 'list']).items.length, 0);
  fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify({ passed: true, syntheticFixture: true, deliveries: seen.length, verified: ['HMAC', '103 interim responses', 'CLI CRUD', 'issue event', 'tag recovery', 'real receive hooks', 'branch/tag deletion', 'restart retry', 'stable identity', 'attempt history', 'no-JS save', 'stale version', 'desktop/mobile'] }, null, 2));
  console.log('Webhook end-to-end acceptance passed. Evidence: _build/webhooks-smoke/receipt.json');
}
main().catch(err => { console.error(err); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close();
  if (server && server.exitCode === null) { server.kill('SIGTERM'); await once(server, 'exit'); }
  if (receiver) await new Promise(r => receiver.close(r));
});
