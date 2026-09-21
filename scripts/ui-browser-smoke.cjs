const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const { spawn, execFileSync } = require('node:child_process');
const { randomBytes } = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const { chromium, request } = require('playwright');

const repo = path.resolve(__dirname, '..');
const output = path.join(repo, '_build', 'ui-browser');
const metadata = path.join(output, 'preview.json');
const binary = process.env.MOONHUB_BINARY || path.join(repo, '_build/native/debug/build/moonhub.exe');
const keep = process.env.MOONHUB_KEEP_PREVIEW === '1';
const reuse = process.env.MOONHUB_REUSE_PREVIEW === '1' && fs.existsSync(metadata);
const previous = reuse ? JSON.parse(fs.readFileSync(metadata, 'utf8')) : null;
const data = previous?.data || fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-ui-'));
const username = 'preview';
const password = previous?.password || randomBytes(24).toString('base64url');
let server, browser, url;
const screenshots = [];
const errors = [];

function git(args, options = {}) {
  return execFileSync('git', args, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], ...options }).trim();
}

async function availablePort() {
  const listener = net.createServer();
  await new Promise((resolve, reject) => { listener.once('error', reject); listener.listen(0, '127.0.0.1', resolve); });
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  return port;
}

async function start() {
  fs.mkdirSync(output, { recursive: true });
  if (previous?.pid) {
    try {
      const command = execFileSync('ps', ['-p', String(previous.pid), '-o', 'command='], { encoding: 'utf8' });
      if (command.includes(binary) && command.includes(data)) process.kill(previous.pid, 'SIGTERM');
    } catch { /* An earlier preview may already be stopped. */ }
  }
  fs.mkdirSync(path.join(data, 'repos'), { recursive: true });
  fs.cpSync(path.join(repo, 'db'), path.join(data, 'db'), { recursive: true });
  fs.writeFileSync(path.join(data, 'password'), password, { mode: 0o600 });
  const port = await availablePort();
  url = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(output, 'server.log'), 'w', 0o600);
  const env = { ...process.env, DB_PATH: path.join(data, 'moonhub.db'), MAIL_OUTBOX_DIR: path.join(data, 'mail') };
  for (const key of ['MOONHUB_ROOT_PASSWORD', 'MOONHUB_ROOT_PASSWORD_FILE', 'MOONHUB_SSH_PUBLIC_URL', 'MOONHUB_SSH_INTERNAL_URL']) delete env[key];
  server = spawn(binary, [path.join(data, 'repos'), '--assets', path.join(repo, 'assets'), '--host', '127.0.0.1', '--port', String(port), '--root-user', username, '--root-password-file', path.join(data, 'password')], { cwd: data, env, detached: true, stdio: ['ignore', log, log] });
  fs.closeSync(log);
  let ready = false;
  for (let attempt = 0; attempt < 150; attempt++) {
    if (server.exitCode !== null) throw new Error(fs.readFileSync(path.join(output, 'server.log'), 'utf8'));
    try { ready = (await fetch(`${url}/login`)).ok; } catch {}
    if (ready) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert(ready, 'preview server did not start');
  fs.writeFileSync(metadata, JSON.stringify({ url, username, password, pid: server.pid, data }, null, 2), { mode: 0o600 });
  console.log(`Preview: ${url}`);
}

async function seed() {
  const api = await request.newContext({ baseURL: url });
  assert.equal((await api.post('/login', { form: { name_key: username, password }, maxRedirects: 0 })).status(), 303);
  assert.equal((await api.post('/change-password', { form: { new_password: password, confirm_password: password }, maxRedirects: 0 })).status(), 303);
  assert.equal((await api.post('/teams', { form: { name_key: 'moonhub', display_name: 'Moonhub' }, maxRedirects: 0 })).status(), 303);
  const work = path.join(data, 'source');
  git(['clone', '--quiet', '--no-hardlinks', path.join(repo, 'testdata/repos/alice/demo.git'), work]);
  git(['-C', work, 'config', 'user.name', 'Preview administrator']);
  git(['-C', work, 'config', 'user.email', 'preview@moonhub.test']);
  git(['-C', work, 'branch', '-M', 'main']);
  for (const file of ['README.md', 'moon.mod', 'navigation.mbt', 'teams.mbt', 'errors.mbt']) fs.copyFileSync(path.join(repo, file), path.join(work, file));
  fs.mkdirSync(path.join(work, 'docs'), { recursive: true });
  fs.copyFileSync(path.join(repo, 'DESIGN.md'), path.join(work, 'docs', 'design.md'));
  git(['-C', work, 'add', '.']);
  git(['-C', work, 'commit', '--quiet', '-m', 'Add the Moonhub workspace interface']);
  git(['-C', work, 'checkout', '--quiet', '-b', 'feature/invitation-feedback']);
  fs.appendFileSync(path.join(work, 'README.md'), '\n## Invitation feedback\n\nPending invitations and delivery status are separate.\n');
  git(['-C', work, 'add', 'README.md']);
  git(['-C', work, 'commit', '--quiet', '-m', 'Clarify invitation delivery and acceptance']);
  git(['-C', work, 'checkout', '--quiet', 'main']);
  fs.mkdirSync(path.join(data, 'repos', 'moonhub'), { recursive: true });
  for (const name of ['moonhub', 'runtime', 'documentation', 'examples']) git(['clone', '--bare', '--quiet', '--no-hardlinks', work, path.join(data, 'repos', 'moonhub', `${name}.git`)]);

  const db = new DatabaseSync(path.join(data, 'moonhub.db'));
  db.exec('PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;');
  const admin = db.prepare('SELECT id,password_hash FROM user WHERE name_key=?').get(username);
  const team = db.prepare('SELECT id FROM team WHERE name_key=?').get('moonhub');
  db.prepare('UPDATE user SET display_name=? WHERE id=?').run('Preview administrator', admin.id);
  const members = [['alex', 'Alex Chen', 'admin'], ['mina', 'Mina Park', 'member'], ['sam', 'Sam Rivera', 'member']];
  for (const [name, display, role] of members) {
    const user = db.prepare('INSERT INTO user(name_key,display_name,email,password_hash) VALUES(?,?,?,?) RETURNING id').get(name, display, `${name}@example.test`, admin.password_hash);
    db.prepare('INSERT INTO team_member(team_id,user_id,role) VALUES(?,?,?)').run(team.id, user.id, role);
  }
  for (const [name, visibility] of [['moonhub', 'private'], ['runtime', 'public'], ['documentation', 'public'], ['examples', 'private']]) db.prepare('INSERT INTO repository(team_id,name,visibility) VALUES(?,?,?)').run(team.id, name, visibility);
  for (const [name, display, status, mail] of [
    ['jules', 'Jules Martin', 'sent', 'pending'], ['casey', 'Casey Wu', 'sent', 'failed'],
    ['mina_invite', 'Mina Park', 'accepted', 'sent'], ['taylor', 'Taylor Kim', 'expired', 'sent'],
  ]) {
    const invitation = db.prepare('INSERT INTO invitation(kind,email,name_key,display_name,password_hash,team_id,team_role,invited_by_user_id,status) VALUES(?,?,?,?,?,?,?,?,?) RETURNING id').get('team_member', `${name}@example.test`, name, display, admin.password_hash, team.id, 'member', admin.id, status);
    db.prepare("INSERT INTO email_outbox(invitation_id,to_email,subject,body,template,status,next_attempt_at,last_error) VALUES(?,?,?,?,?,?,datetime('now','+1 day'),?)").run(invitation.id, `${name}@example.test`, 'Invitation to Moonhub', `Username: ${name}\nOne-time password: ${password}\n`, 'team_invitation', mail, mail === 'failed' ? 'fixture-mail-diagnostic: do-not-render' : null);
  }
  db.close();
  await api.dispose();
}

async function login(page) {
  await page.goto(`${url}/login`);
  await page.getByLabel('Username or email', { exact: true }).fill(username);
  await page.getByLabel('Password', { exact: true }).fill(password);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL(`${url}/`);
  await page.waitForFunction(() => document.documentElement.dataset.uiReady === 'true');
}

async function seedCollaboration(page) {
  await page.goto(`${url}/moonhub/moonhub/issues/new`);
  const csrf = await page.locator('form input[name=csrf_token]').inputValue();
  for (const [title, description] of [
    ['Keep invitation feedback close to the form', 'Preserve the entered email, username and role when validation fails.'],
    ['Review the workspace navigation on small screens', 'Verify keyboard focus and the mobile navigation drawer.'],
    ['Align repository and team status labels', 'Use distinct labels for invitation acceptance and mail delivery.'],
  ]) {
    const response = await page.context().request.post(`${url}/moonhub/moonhub/issues`, { form: { csrf_token: csrf, title, description, assignee: '0' }, maxRedirects: 0 });
    assert.equal(response.status(), 303);
  }
  await page.goto(`${url}/moonhub/moonhub/merge-requests/new`);
  await page.getByLabel('Source branch').selectOption('feature/invitation-feedback');
  await page.getByLabel('Target branch').selectOption('main');
  await page.getByLabel('Title', { exact: true }).fill('Clarify invitation delivery and acceptance');
  await page.getByLabel('Description', { exact: true }).fill('Separate acceptance from mail delivery and keep recovery actions next to the affected invitation.');
  await page.getByRole('button', { name: 'Create merge request', exact: true }).click();
  await page.waitForURL(`${url}/moonhub/moonhub/merge-requests/1`);
}

async function capture(page, name, viewport) {
  await page.setViewportSize(viewport);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForFunction(() => [...document.querySelectorAll('[data-icon]')]
    .every(element => getComputedStyle(element, '::before').maskImage !== 'none'));
  const layout = await page.evaluate(() => {
    const width = document.documentElement.clientWidth;
    const clipped = [...document.querySelectorAll('main input, main select, main textarea, main button, main h1, main h2')]
      .filter(element => element.checkVisibility() && !element.closest('.table-scroll'))
      .filter(element => { const r = element.getBoundingClientRect(); return r.left < -1 || r.right > width + 1; })
      .map(element => element.textContent || element.name || element.tagName);
    return { overflow: document.documentElement.scrollWidth > width + 1, clipped };
  });
  assert.deepEqual(layout, { overflow: false, clipped: [] }, `${name} layout`);
  const file = path.join(output, `${name}.png`);
  await page.screenshot({ path: file, fullPage: !name.includes('navigation'), animations: 'disabled' });
  screenshots.push(file);
}

async function verifyCommitDiff(page, route) {
  await page.goto(url + route);
  await page.locator('.moonhub-code-view-frame').waitFor();
  await page.locator('diffs-container [data-code]').first().waitFor();
  assert.equal(await page.locator('diffs-container [data-error-stack]').count(), 0);
  assert(await page.locator('moonhub-commit-diff > pre[data-patch]').evaluate(element => element.hidden));
  assert.equal(await page.locator('pre[data-patch] > *').count(), 0);
  const commit = route.split('/').at(-1);
  const expected = git([
    `--git-dir=${path.join(data, 'repos/moonhub/moonhub.git')}`,
    'show', '--format=', '--no-color', '--no-ext-diff', '--no-textconv',
    '--diff-algorithm=histogram', '--diff-merges=first-parent', '--patch',
    '--find-renames', '--src-prefix=a/', '--dst-prefix=b/', commit, '--',
  ]);
  assert.equal((await page.locator('pre[data-patch]').textContent()).trim(), expected);
  assert.equal(await page.evaluate(() => window.__moonhubPatchExecuted), undefined);
}

async function verify(page) {
  const desktop = { width: 1400, height: 900 };
  const mobile = { width: 390, height: 844 };
  await page.setViewportSize(desktop);
  await page.goto(`${url}/`);
  await page.getByLabel('Find a repository').fill('not-present');
  await page.getByText('No matching repositories.', { exact: true }).waitFor();
  assert.equal(await page.locator('[data-filter-item]:visible').count(), 0);
  await page.getByLabel('Find a repository').fill('runtime');
  assert.equal(await page.locator('[data-filter-item]:visible').count(), 1);
  await page.getByLabel('Find a repository').fill('');
  await page.getByRole('button', { name: 'Collapse sidebar', exact: true }).click();
  assert.equal(await page.locator('.sidebar').evaluate(element => Math.round(element.getBoundingClientRect().width)), 64);
  await page.reload();
  await page.getByRole('button', { name: 'Expand sidebar', exact: true }).waitFor();
  assert.equal(await page.locator('.sidebar').evaluate(element => Math.round(element.getBoundingClientRect().width)), 64);
  await page.getByRole('button', { name: 'Expand sidebar', exact: true }).click();
  assert.equal(await page.locator('.sidebar').evaluate(element => Math.round(element.getBoundingClientRect().width)), 224);
  await page.goto(`${url}/moonhub?tab=invitations`);
  const invitationMenu = page.locator('.row-menu').first();
  await invitationMenu.locator('summary').click();
  await invitationMenu.getByRole('button', { name: 'View sign-in details', exact: true }).waitFor();
  await page.keyboard.press('Escape');
  assert.equal(await invitationMenu.getAttribute('open'), null);

  const pages = [
    ['repositories', '/'], ['team', '/moonhub'], ['members', '/moonhub?tab=members'],
    ['invitations', '/moonhub?tab=invitations'], ['invite-form', '/moonhub?tab=invitations&invite=1'],
    ['files', '/moonhub/moonhub'], ['issues', '/moonhub/moonhub/issues'],
    ['merge-requests', '/moonhub/moonhub/merge-requests'], ['merge-detail', '/moonhub/moonhub/merge-requests/1'],
    ['ssh-keys', '/settings/ssh-keys'], ['site-settings', '/admin/settings/ssh'],
  ];
  for (const [name, route] of pages) {
    const response = await page.goto(url + route);
    assert.equal(response.status(), 200, route);
    await page.waitForFunction(() => document.documentElement.dataset.uiReady === 'true');
    assert(!await page.locator('body').textContent().then(text => text.includes('fixture-mail-diagnostic')));
    await capture(page, `desktop-${name}`, desktop);
    await capture(page, `mobile-${name}`, mobile);
    if (name === 'files') {
      const entries = await page.locator('.file-table tbody tr').evaluateAll(rows => rows.map(row => ({
        name: row.querySelector('.file-link').textContent,
        directory: row.querySelector('[data-icon="folder"]') !== null,
      })));
      assert.deepEqual(await page.locator('.file-table th').allTextContents(), ['Name', 'Size']);
      await page.locator('.file-table th').last().waitFor({ state: 'visible' });
      const directories = entries.filter(entry => entry.directory).map(entry => entry.name).sort();
      const files = entries.filter(entry => !entry.directory).map(entry => entry.name).sort();
      assert(directories.length > 0 && files.length > 0);
      assert.deepEqual(entries.map(entry => entry.name), [...directories, ...files]);
    }
  }
  await page.goto(`${url}/moonhub?tab=invitations`);
  await capture(page, 'small-mobile-invitations', { width: 320, height: 740 });
  await page.getByRole('button', { name: 'Open navigation', exact: true }).click();
  await page.getByRole('dialog', { name: 'Workspace navigation' }).waitFor();
  assert(await page.locator('main').evaluate(element => element.inert));
  await capture(page, 'mobile-navigation', mobile);
  await page.keyboard.press('Escape');
  assert(!await page.locator('main').evaluate(element => element.inert));
  assert(await page.getByRole('button', { name: 'Open navigation', exact: true }).evaluate(element => element === document.activeElement));
  await page.getByRole('button', { name: 'Open navigation', exact: true }).click();
  await page.getByRole('link', { name: 'Members', exact: true }).click();
  await page.waitForURL(`${url}/moonhub?tab=members`);
  assert(await page.locator('#team-invitations').evaluate(element => element.hidden));
  assert(!await page.locator('#team-members').evaluate(element => element.hidden));

  await page.setViewportSize(desktop);
  await page.goto(`${url}/moonhub?tab=invitations&invite=1`);
  await page.getByLabel('Email', { exact: true }).fill('new-member@example.test');
  await page.getByLabel('Username', { exact: true }).fill('INVALID');
  await page.getByLabel('Display name', { exact: true }).fill('New member <Preview>');
  await page.getByLabel('Role', { exact: true }).selectOption('admin');
  const invalidResponse = page.waitForResponse(response => response.request().method() === 'POST' && response.url().endsWith('/invitations'));
  await page.getByRole('button', { name: 'Send invite', exact: true }).click();
  assert.equal((await invalidResponse).status(), 400);
  await page.getByRole('alert').waitFor();
  assert.equal(await page.getByLabel('Email', { exact: true }).inputValue(), 'new-member@example.test');
  assert.equal(await page.getByLabel('Display name', { exact: true }).inputValue(), 'New member <Preview>');
  assert.equal(await page.getByLabel('Role', { exact: true }).inputValue(), 'admin');
  await capture(page, 'desktop-invite-validation', desktop);
  await capture(page, 'mobile-invite-validation', mobile);
  const unique = `guest_${randomBytes(4).toString('hex')}`;
  await page.getByLabel('Username', { exact: true }).fill(unique);
  await page.getByLabel('Email', { exact: true }).fill(`${unique}@example.test`);
  await page.getByRole('button', { name: 'Send invite', exact: true }).click();
  await page.getByText('Invitation created.', { exact: true }).waitFor();
  assert(await page.locator('.invite-form').evaluate(element => element.hidden));

  await page.setViewportSize({ width: 1920, height: 1080 });
  await page.goto(`${url}/moonhub/moonhub/blob/main/navigation.mbt`);
  await page.locator('.moonhub-code-view-frame').waitFor();
  await page.locator('diffs-container [data-code]').first().waitFor();
  assert.equal(await page.locator('diffs-container [data-error-stack]').count(), 0);
  assert((await page.locator('.moonhub-code-view-frame').boundingBox()).width > 1180);
  await capture(page, 'wide-code', { width: 1920, height: 1080 });
  await capture(page, 'mobile-code', mobile);
  await page.goto(`${url}/moonhub/moonhub/merge-requests/1?tab=changes`);
  await page.locator('.moonhub-code-view-frame').waitFor();
  await page.locator('diffs-container [data-code]').first().waitFor();
  assert.equal(await page.locator('diffs-container [data-error-stack]').count(), 0);
  await capture(page, 'desktop-diff', desktop);
  await capture(page, 'mobile-diff', mobile);

  await page.goto(`${url}/moonhub/moonhub/commits`);
  const commitRoute = await page.locator('main a[href*="/commit/"]').first().getAttribute('href');
  await verifyCommitDiff(page, commitRoute);
  await capture(page, 'desktop-commit', desktop);
  await capture(page, 'mobile-commit', mobile);

  const gitDir = `--git-dir=${path.join(data, 'repos/moonhub/moonhub.git')}`;
  const original = git([gitDir, 'rev-parse', 'main']);
  const initial = git([gitDir, 'rev-list', '--max-parents=0', 'main']).split('\n')[0];
  await verifyCommitDiff(page, `/moonhub/moonhub/commit/${initial}`);
  const content = '</pre><script>window.__moonhubPatchExecuted = true</script>\n<div>A &amp; B</div>\n';
  const blob = git([gitDir, 'hash-object', '-w', '--stdin'], { input: content });
  const tree = git([gitDir, 'mktree'], { input: `100644 blob ${blob}\tchanges.html\n` });
  const identity = ['-c', 'user.name=Preview', '-c', 'user.email=preview@moonhub.test'];
  const source = git([gitDir, ...identity, 'commit-tree', tree, '-p', original, '-m', 'HTML patch regression']);
  const merge = git([gitDir, ...identity, 'commit-tree', tree, '-p', original, '-p', source, '-m', 'Merge HTML changes']);
  const empty = git([gitDir, ...identity, 'commit-tree', tree, '-p', merge, '-m', 'Empty change']);
  await verifyCommitDiff(page, `/moonhub/moonhub/commit/${source}`);
  await verifyCommitDiff(page, `/moonhub/moonhub/commit/${merge}`);
  await capture(page, 'desktop-merge-commit', desktop);
  await capture(page, 'mobile-merge-commit', mobile);
  await page.goto(`${url}/moonhub/moonhub/commit/${empty}`);
  await page.getByText('No file changes.', { exact: true }).waitFor();
  assert.equal(await page.locator('moonhub-commit-diff').count(), 0);

  await page.setViewportSize(desktop);
  await page.locator('.account-menu > summary').click();
  await page.locator('.account-menu-panel').getByRole('link', { name: 'SSH keys', exact: true }).click();
  await page.waitForURL(`${url}/settings/ssh-keys`);
  if (await page.getByRole('heading', { name: 'Preview laptop', exact: true }).count() === 0) {
    await page.getByRole('link', { name: 'Add SSH key', exact: true }).click();
    await page.getByLabel('Name', { exact: true }).fill('Preview laptop');
    await page.getByLabel('Public key (Ed25519)', { exact: true }).fill('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB');
    await page.getByRole('button', { name: 'Add SSH key', exact: true }).click();
    await page.waitForURL(`${url}/settings/ssh-keys`);
  }
  await page.getByText('Preview laptop', { exact: true }).waitFor();
  await capture(page, 'desktop-ssh-key-added', desktop);
  assert.deepEqual(errors, []);
}

async function main() {
  await start();
  if (!reuse) await seed();
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
  const page = await context.newPage();
  page.setDefaultTimeout(15000);
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => {
    if (message.type() === 'error' && message.text().startsWith('moonhub commit diff failed')) errors.push(message.text());
  });
  await page.goto(`${url}/login`);
  await capture(page, 'desktop-login', { width: 1400, height: 900 });
  await capture(page, 'mobile-login', { width: 390, height: 844 });
  await login(page);
  if (!reuse) await seedCollaboration(page);
  await verify(page);
  fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify({ url, screenshots, errors, passed: true }, null, 2));
  console.log(`UI smoke passed: navigation, directory ordering, invitations, code, MR and commit diffs, escaped patches, root/merge/empty commits, SSH key workflow. ${screenshots.length} screenshots.`);
}

main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close();
  if (server && keep) server.unref();
  else if (server && server.exitCode === null) {
    server.kill('SIGTERM');
    await new Promise(resolve => server.once('exit', resolve));
  }
  if (!keep) fs.rmSync(data, { recursive: true, force: true });
});
