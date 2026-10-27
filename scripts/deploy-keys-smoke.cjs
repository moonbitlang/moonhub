const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { randomBytes } = require('node:crypto');
const { execFileSync, spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const docker = process.env.MOONHUB_SMOKE_DOCKER === '1';
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-deploy-keys-'));
const output = path.join(root, '_build', docker ? 'deploy-keys-docker' : 'deploy-keys-smoke');
const binary = process.env.MOONHUB_BINARY || path.join(root, '_build/native/debug/build/moonhub.exe');
const password = randomBytes(24).toString('hex');
const env = { ...process.env, DB_PATH: path.join(temp, 'moonhub.db'),
  MOONHUB_REPO_ROOT: path.join(temp, 'repos'), MOONHUB_HOOKS_PATH: path.join(temp, 'hooks'),
  MOONHUB_BIN: binary, MAIL_OUTBOX_DIR: path.join(temp, 'mail'),
  MOONHUB_SMOKE_SECRET: path.join(temp, 'password'), MOONHUB_SSH_IMPORT_DIR: path.join(temp, 'imports') };
// Never allow an operator's production volume overrides into the disposable project.
delete env.MOONHUB_DATA_VOLUME;
delete env.MOONHUB_SSH_KEYS_VOLUME;
const project = `moonhub-deploy-keys-${Date.now()}-${process.pid}`;
const compose = ['compose', '--env-file', '/dev/null', '--project-name', project,
  '-f', path.join(root, 'compose.yaml'), '-f', path.join(root, 'deploy/compose.smoke.yaml')];
let server, browser, base, cookie, sshPort, transport, keep = false, composeStarted = false;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const run = (command, args, options = {}) => execFileSync(command, args,
  { cwd: root, env, encoding: 'utf8', timeout: 30000, stdio: ['pipe', 'pipe', 'pipe'], ...options }).trim();
const dc = args => run('docker', [...compose, ...args], { timeout: 240000 });
const cli = (args, input) => docker
  ? run('docker', [...compose, 'exec', '-T', '--user', 'git', 'web', 'moonhub', ...args], { input })
  : run(binary, args, { input });
function query(sql) {
  if (docker) return JSON.parse(dc(['exec', '-T', '--user', 'git', 'web', 'node', '--no-warnings', '-e',
    'const db = new (require("node:sqlite").DatabaseSync)(process.env.DB_PATH); console.log(JSON.stringify(db.prepare(process.argv[1]).all())); db.close();', sql]));
  const db = new (require('node:sqlite').DatabaseSync)(env.DB_PATH);
  try { return db.prepare(sql).all(); } finally { db.close(); }
}
async function request(route, fields) {
  const response = await fetch(base + route, { method: fields ? 'POST' : 'GET', redirect: 'manual',
    headers: cookie ? { Cookie: cookie } : {}, body: fields ? new URLSearchParams(fields) : undefined,
    signal: AbortSignal.timeout(10000) });
  if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
  return { status: response.status, body: await response.text() };
}
async function start() {
  fs.mkdirSync(output, { recursive: true });
  for (const dir of ['repos', 'hooks', 'imports']) fs.mkdirSync(path.join(temp, dir));
  fs.writeFileSync(env.MOONHUB_SMOKE_SECRET, password, { mode: 0o600 });
  if (docker) {
    composeStarted = true;
    dc(['up', '--no-build', '-d', '--wait', '--wait-timeout', '180']);
    base = 'http://' + dc(['port', 'web', '8080']);
    sshPort = dc(['port', 'ssh', '2222']).split(':').pop();
    const hostKey = dc(['exec', '-T', 'ssh', 'cat', '/var/lib/moonhub/ssh/ssh_host_ed25519_key.pub']);
    fs.writeFileSync(path.join(temp, 'known_hosts'), `[127.0.0.1]:${sshPort} ${hostKey}\n`, { mode: 0o600 });
  } else {
    for (const hook of ['pre-receive', 'reference-transaction']) {
      fs.copyFileSync(path.join(root, 'deploy/hooks', hook), path.join(env.MOONHUB_HOOKS_PATH, hook));
      fs.chmodSync(path.join(env.MOONHUB_HOOKS_PATH, hook), 0o755);
    }
    const listener = net.createServer();
    await new Promise((resolve, reject) => { listener.once('error', reject); listener.listen(0, '127.0.0.1', resolve); });
    const port = listener.address().port;
    await new Promise(resolve => listener.close(resolve));
    base = `http://127.0.0.1:${port}`;
    const log = fs.openSync(path.join(output, 'server.log'), 'w', 0o600);
    server = spawn(binary, [env.MOONHUB_REPO_ROOT, '--assets', path.join(root, 'assets'), '--host', '127.0.0.1',
      '--port', String(port), '--root-user', 'root', '--root-password-file', env.MOONHUB_SMOKE_SECRET],
    { cwd: root, env, detached: true, stdio: ['ignore', log, log] });
    fs.closeSync(log);
    for (let i = 0; i < 200; i++) {
      if (server.exitCode !== null) throw new Error(fs.readFileSync(path.join(output, 'server.log'), 'utf8'));
      try { if ((await fetch(base + '/-/login')).ok) break; } catch {}
      if (i === 199) throw new Error('server did not start');
      await delay(100);
    }
    transport = path.join(temp, 'ssh');
    fs.writeFileSync(transport, '#!/bin/sh\nfor arg do SSH_ORIGINAL_COMMAND=$arg; done\nexport SSH_ORIGINAL_COMMAND\nexec "$MOONHUB_BIN" ssh-serve "$MOONHUB_TEST_CREDENTIAL"\n', { mode: 0o700 });
  }
}
function sshArgs(identity, control = false) {
  const args = ['-F', '/dev/null', '-i', path.join(temp, identity), '-p', sshPort,
    '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none', '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=yes', '-o', `UserKnownHostsFile=${path.join(temp, 'known_hosts')}`];
  if (control) args.push('-S', path.join(temp, 'control'));
  return args;
}
function git(args, identity, credential, cwd = path.join(temp, 'source')) {
  const gitEnv = { ...env };
  delete gitEnv.GIT_SSH_COMMAND;
  delete gitEnv.GIT_SSH;
  if (docker) gitEnv.GIT_SSH_COMMAND = ['ssh', ...sshArgs(identity)].map(arg => `'${arg.replaceAll("'", "'\\''")}'`).join(' ');
  else Object.assign(gitEnv, { GIT_SSH: transport, GIT_SSH_VARIANT: 'simple', MOONHUB_TEST_CREDENTIAL: credential });
  return run('git', args, { cwd, env: gitEnv });
}
function denied(f, message) {
  assert.throws(f, error => error.status !== 0 && error.status !== undefined, message);
}
async function capture(page, state) {
  for (const width of [1280, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    await page.evaluate(() => document.fonts.ready);
    await page.waitForFunction(() => {
      const sidebar = document.querySelector('#app-sidebar');
      return !sidebar || getComputedStyle(sidebar).position !== 'fixed' || getComputedStyle(sidebar).visibility === 'hidden';
    });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth), false, `${state} overflow at ${width}`);
    await page.screenshot({ path: path.join(output, `${state}-${width}.png`), fullPage: true });
  }
  await page.setViewportSize({ width: 1280, height: 900 });
}
function waitingHook(name, credential, args = []) {
  const child = docker
    ? spawn('docker', [...compose, 'exec', '-T', '--user', 'git', 'web', 'moonhub', name, credential, 'root/demo', ...args], { cwd: root, env, stdio: ['pipe', 'pipe', 'pipe'] })
    : spawn(binary, [name, credential, 'root/demo', ...args], { cwd: root, env, stdio: ['pipe', 'pipe', 'pipe'] });
  const exited = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', code => resolve(code));
  });
  return async () => {
    child.stdin.end(`${'0'.repeat(40)} ${'a'.repeat(40)} refs/heads/topic\n`);
    assert.notEqual(await exited, 0, `${name} accepted authorization from before downgrade`);
  };
}
async function main() {
  await start();
  assert.equal((await request('/-/login', { name_key: 'root', password })).status, 303);
  assert.equal((await request('/-/change-password', { new_password: password, confirm_password: password })).status, 303);
  cli(['repo-create', 'root/demo']);
  cli(['repo-create', 'root/other', '--visibility', 'public']);
  for (const name of ['user', 'deploy', 'other']) run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', path.join(temp, name)]);
  const userKey = cli(['ssh-key-add', 'root'], fs.readFileSync(path.join(temp, 'user.pub'))).split('\t')[0];
  const url = name => docker ? `ssh://git@127.0.0.1:${sshPort}/root/${name}.git` : `test-host:/root/${name}.git`;
  const source = path.join(temp, 'source');
  fs.mkdirSync(source);
  git(['init', '-q', '-b', 'main'], 'user', userKey);
  git(['config', 'user.name', 'Deploy acceptance'], 'user', userKey);
  git(['config', 'user.email', 'test@example.invalid'], 'user', userKey);
  fs.mkdirSync(path.join(source, '.github/workflows'), { recursive: true });
  fs.writeFileSync(path.join(source, '.github/workflows/check.yml'), 'name: Check\non:\n  push:\n  workflow_dispatch:\njobs:\n  check:\n    runs-on: [self-hosted, linux]\n    steps:\n      - run: echo ok\n');
  fs.writeFileSync(path.join(source, 'binary'), Buffer.from([0, 1, 2, 255, 128]));
  git(['add', '.'], 'user', userKey);
  git(['commit', '-qm', 'initial'], 'user', userKey);
  git(['push', url('demo'), 'HEAD:main'], 'user', userKey);

  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const split = cookie.indexOf('=');
  await context.addCookies([{ name: cookie.slice(0, split), value: cookie.slice(split + 1), url: base }]);
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const route = '/root/demo/settings/deploy-keys';
  await page.goto(base + route);
  await page.getByText('No deploy keys.', { exact: true }).waitFor();
  await capture(page, 'empty');
  await page.getByRole('link', { name: 'Add deploy key', exact: true }).click();
  assert.equal(await page.getByLabel('Allow write access').isChecked(), false);
  await page.getByLabel('Name', { exact: true }).fill('DeploymentServer'.repeat(12));
  await page.getByLabel('Public key (Ed25519)').fill('-----BEGIN OPENSSH PRIVATE KEY-----\nsecret-must-not-echo');
  await page.getByRole('button', { name: 'Add deploy key', exact: true }).click();
  await page.getByRole('alert').waitFor();
  assert.equal(await page.getByLabel('Public key (Ed25519)').inputValue(), '');
  assert.ok(!(await page.content()).includes('secret-must-not-echo'));
  await capture(page, 'validation');
  await page.getByLabel('Public key (Ed25519)').fill(fs.readFileSync(path.join(temp, 'deploy.pub'), 'utf8'));
  await page.getByRole('button', { name: 'Add deploy key', exact: true }).click();
  await page.waitForURL(base + route);
  const row = query('SELECT id, write_access, last_used_at FROM repository_deploy_key')[0];
  const credential = `deploy:${row.id}`;
  assert.equal(row.write_access, 0);
  assert.equal(row.last_used_at, null);
  const publicParts = fs.readFileSync(path.join(temp, 'deploy.pub'), 'utf8').trim().split(' ');
  assert.ok(cli(['ssh-authorized-key', 'git', ...publicParts.slice(0, 2)]).includes(`ssh-serve ${credential}`));
  git(['clone', url('demo'), path.join(temp, 'clone')], 'deploy', credential);
  assert.deepEqual(fs.readFileSync(path.join(temp, 'clone/binary')), fs.readFileSync(path.join(source, 'binary')));
  git(['fetch', 'origin'], 'deploy', credential, path.join(temp, 'clone'));
  git(['pull', '--ff-only'], 'deploy', credential, path.join(temp, 'clone'));
  assert.ok(query('SELECT last_used_at FROM repository_deploy_key')[0].last_used_at);
  denied(() => git(['push', url('demo'), 'HEAD:denied'], 'deploy', credential), 'read-only push succeeded');
  denied(() => git(['ls-remote', url('other')], 'deploy', credential), 'read key escaped repository');
  await page.reload();
  await capture(page, 'read-only');
  await page.getByRole('link', { name: /^Edit access for/ }).click();
  await page.getByLabel('Allow write access').check();
  await capture(page, 'access');
  await page.getByRole('button', { name: 'Save access', exact: true }).click();
  await page.waitForURL(base + route);
  await page.goto(base + '/root/demo/pipelines');
  await page.getByLabel('Run push workflows').check();
  await page.getByRole('button', { name: 'Save settings', exact: true }).click();
  await page.waitForURL(base + '/root/demo/pipelines');
  // Older Git includes an implicit HEAD update in the trusted transaction.
  // HEAD is still forbidden as a client ref submitted to pre-receive.
  const headUpdate = `${'0'.repeat(40)} ${'a'.repeat(40)} HEAD\n`;
  cli(['ssh-ref-transaction', credential, 'root/demo', 'a'.repeat(32), 'prepared'], headUpdate);
  denied(() => cli(['ssh-pre-receive', credential, 'root/demo'], headUpdate), 'client HEAD ref was accepted');
  git(['commit', '--allow-empty', '-qm', 'deploy push'], 'user', userKey);
  git(['push', url('demo'), 'HEAD:main'], 'deploy', credential);
  denied(() => git(['push', url('other'), 'HEAD:main'], 'deploy', credential), 'write key escaped repository');
  assert.equal(query('SELECT count(*) AS count FROM repository_ref_event')[0].count, 0);
  await delay(1200);
  assert.equal(query('SELECT count(*) AS count FROM pipeline_run')[0].count, 0);
  // The equivalent user push must still create an executable event.
  git(['commit', '--allow-empty', '-qm', 'user push'], 'user', userKey);
  git(['push', url('demo'), 'HEAD:main'], 'user', userKey);
  for (let i = 0; i < 100 && !query('SELECT id FROM pipeline_run').length; i++) await delay(100);
  assert.equal(query('SELECT count(*) AS count FROM pipeline_run')[0].count, 1);
  await page.goto(base + '/root/demo/settings/branches');
  await page.locator('[name=branch]').fill('main');
  await page.locator('form button[type=submit]').last().click();
  await page.waitForURL(base + '/root/demo/settings/branches');
  git(['commit', '--allow-empty', '-qm', 'protected push'], 'user', userKey);
  denied(() => git(['push', url('demo'), 'HEAD:main'], 'deploy', credential), 'protected push succeeded');
  denied(() => git(['push', url('demo'), ':refs/heads/main'], 'deploy', credential), 'protected deletion succeeded');
  denied(() => git(['push', url('demo'), 'HEAD:refs/moonhub/attack'], 'deploy', credential), 'internal ref push succeeded');
  assert.equal(query('SELECT count(*) AS count FROM pipeline_run')[0].count, 1);
  if (docker) {
    run('ssh', [...sshArgs('deploy'), '-M', '-S', path.join(temp, 'control'), '-fN', 'git@127.0.0.1']);
    denied(() => run('ssh', [...sshArgs('deploy', true), 'git@127.0.0.1', "git-upload-pack 'root/other.git'"]), 'changed SSH command escaped binding');
    denied(() => run('ssh', [...sshArgs('deploy'), 'git@127.0.0.1', 'id']), 'shell command succeeded');
    denied(() => run('ssh', [...sshArgs('deploy'), '-o', 'ExitOnForwardFailure=yes', '-R', '0:127.0.0.1:8080', 'git@127.0.0.1']), 'forwarding succeeded');
  }
  const hooks = [waitingHook('ssh-pre-receive', credential),
    waitingHook('ssh-ref-transaction', credential, ['a'.repeat(32), 'prepared'])];
  await delay(250);
  await page.goto(base + `${route}/${row.id}/access`);
  await page.getByLabel('Allow write access').uncheck();
  await page.getByRole('button', { name: 'Save access', exact: true }).click();
  await page.waitForURL(base + route);
  for (const finish of hooks) await finish();
  denied(() => git(['push', url('demo'), 'HEAD:topic'], 'deploy', credential), 'downgraded key pushed');
  git(['ls-remote', url('demo')], 'deploy', credential);
  await page.getByRole('link', { name: /^Revoke DeploymentServer/ }).click();
  await capture(page, 'revoke-confirmation');
  await page.getByRole('button', { name: 'Revoke deploy key', exact: true }).click();
  await page.waitForURL(base + route);
  await capture(page, 'revoked');
  denied(() => git(['ls-remote', url('demo')], 'deploy', credential), 'revoked key fetched');
  if (docker) denied(() => run('ssh', [...sshArgs('deploy', true), 'git@127.0.0.1', "git-upload-pack 'root/demo.git'"]), 'revoked key reused SSH connection');
  assert.equal(cli(['ssh-authorized-key', 'git', ...publicParts.slice(0, 2)]), '');
  assert.deepEqual(query("SELECT kind FROM repository_audit WHERE kind LIKE 'deploy_key_%' ORDER BY id").map(row => row.kind),
    ['deploy_key_added', 'deploy_key_access_changed', 'deploy_key_access_changed', 'deploy_key_revoked']);
  assert.deepEqual(errors, []);
  console.log(`Deploy key acceptance passed (${docker ? 'real OpenSSH' : 'local Git transport adapter'}): clone/fetch/pull, read/write isolation, protected refs, Pipeline exclusion, downgrade, revocation, audit and responsive UI.`);
  if (!docker && process.env.MOONHUB_KEEP_PREVIEW === '1') {
    fs.writeFileSync(path.join(output, 'preview.json'), JSON.stringify({ url: base + route, username: 'root', passwordFile: env.MOONHUB_SMOKE_SECRET, pid: server.pid, directory: temp }, null, 2), { mode: 0o600 });
    keep = true;
    server.unref();
    console.log(`Preview: ${base + route}; credentials: ${path.join(output, 'preview.json')}`);
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close();
  if (docker && fs.existsSync(path.join(temp, 'control'))) spawnSync('ssh', [...sshArgs('deploy', true), '-O', 'exit', 'git@127.0.0.1']);
  if (composeStarted) {
    if (process.exitCode) console.error(dc(['logs', '--no-color', '--tail', '50']));
    dc(['down', '--volumes', '--remove-orphans']);
  }
  if (!keep) {
    if (server && server.exitCode === null) {
      const stopped = new Promise(resolve => server.once('exit', resolve));
      process.kill(-server.pid, 'SIGTERM');
      await stopped;
    }
    fs.rmSync(temp, { recursive: true, force: true });
  }
});
