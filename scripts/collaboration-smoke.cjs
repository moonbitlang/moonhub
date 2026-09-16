const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { randomBytes } = require('node:crypto');
const { spawnSync, execFileSync } = require('node:child_process');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-collaboration-'));
const output = path.join(root, '_build/collaboration-browser');
fs.mkdirSync(output, { recursive: true });
fs.mkdirSync(path.join(temporary, 'imports'));
const secret = path.join(temporary, 'password');
const password = randomBytes(24).toString('hex');
fs.writeFileSync(secret, password, { mode: 0o600 });
const project = `moonhub-collaboration-${Date.now()}`;
const composeArgs = ['compose', '--env-file', '/dev/null', '-p', project,
  '-f', path.join(root, 'compose.yaml'), '-f', path.join(root, 'deploy/compose.smoke.yaml'),
  '-f', path.join(root, 'deploy/compose.collaboration-smoke.yaml')];
const env = { ...process.env, MOONHUB_SMOKE_SECRET: secret, MOONHUB_SSH_IMPORT_DIR: path.join(temporary, 'imports') };
let browser;

function compose(args, options = {}) {
  return execFileSync('docker', [...composeArgs, ...args], { cwd: root, env, encoding: 'utf8', maxBuffer: 10 * 1024 * 1024, ...options }).trim();
}

async function capture(page, name) {
  for (const width of [1280, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    const layout = await page.evaluate(() => {
      const width = document.documentElement.clientWidth;
      const elements = [...document.querySelectorAll('a,button,input:not([type=hidden]),select,textarea,summary')].filter(e => e.checkVisibility());
      const outside = elements.filter(e => { const r = e.getBoundingClientRect(); return r.left < -1 || r.right > width + 1; }).map(e => e.name || e.textContent);
      const overlap = [];
      for (let i = 0; i < elements.length; i++) for (let j = i + 1; j < elements.length; j++) {
        if (elements[i].contains(elements[j]) || elements[j].contains(elements[i])) continue;
        const a = elements[i].getBoundingClientRect(), b = elements[j].getBoundingClientRect();
        if (Math.min(a.right, b.right) - Math.max(a.left, b.left) > 1 && Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 1) overlap.push([elements[i].name || elements[i].textContent, elements[j].name || elements[j].textContent]);
      }
      return { overflow: document.documentElement.scrollWidth > width, outside, overlap };
    });
    assert.deepEqual(layout, { overflow: false, outside: [], overlap: [] }, `${name} at ${width}px`);
    await page.screenshot({ path: path.join(output, `${name}-${width}.png`), fullPage: true });
  }
}

async function activate(page, base, username, initial, replacement) {
  await page.goto(base + '/login');
  await page.locator('[name=name_key]').fill(username);
  await page.locator('[name=password]').fill(initial);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL(base + '/change-password');
  await page.locator('[name=new_password]').fill(replacement);
  await page.locator('[name=confirm_password]').fill(replacement);
  await page.getByRole('button', { name: 'Set password', exact: true }).click();
  await page.waitForURL(base + '/');
}

async function main() {
  compose(['up', '-d', '--no-build', '--wait', '--wait-timeout', '180']);
  const base = 'http://' + compose(['port', 'web', '8080']);
  const sshPort = compose(['port', 'ssh', '2222']).split(':').at(-1);
  browser = await chromium.launch({ headless: true });
  const owner = await browser.newPage();
  const errors = [];
  owner.on('pageerror', error => errors.push(error.message));
  await activate(owner, base, 'root', password, password);
  await owner.goto(base + '/teams');
  await owner.getByRole('link', { name: 'New team', exact: true }).click();
  await owner.locator('[name=name_key]').fill('engineering');
  await owner.locator('[name=display_name]').fill('Engineering');
  await owner.getByRole('button', { name: 'Create team', exact: true }).click();
  await owner.waitForURL(base + '/teams/engineering');
  await owner.goto(base + '/teams/engineering?tab=invitations&invite=1');
  await owner.locator('[name=email]').fill('reviewer@example.com');
  await owner.locator('[name=name_key]').fill('reviewer');
  await owner.locator('[name=display_name]').fill('Reviewer');
  await owner.locator('[name=role]').selectOption('member');
  await owner.locator('form[action$="/invitations"] button[type=submit]').click();
  const mailPath = '/data/mail_outbox';
  let mail = '';
  for (let i = 0; i < 50; i++) {
    const files = compose(['exec', '-T', 'web', 'ls', mailPath]).split('\n').filter(Boolean);
    for (const file of files) mail += compose(['exec', '-T', 'web', 'cat', `${mailPath}/${file}`]);
    if (mail.includes('One-time password: ')) break;
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  const invited = mail.match(/One-time password: ([^\s]+)/)?.[1];
  assert(invited, 'invitation email missing');
  const reviewer = await browser.newPage();
  reviewer.on('pageerror', error => errors.push(error.message));
  await activate(reviewer, base, 'reviewer', invited, password);

  const key = path.join(temporary, 'key');
  execFileSync('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', key]);
  compose(['exec', '-T', '--user', 'git', 'web', 'moonhub', 'ssh-key-add', 'root', '--title', 'Smoke'], { input: fs.readFileSync(key + '.pub') });
  const hostKey = compose(['exec', '-T', 'ssh', 'cat', '/var/lib/moonhub/ssh/ssh_host_ed25519_key.pub']).split(/\s+/).slice(0, 2).join(' ');
  const known = path.join(temporary, 'known_hosts');
  fs.writeFileSync(known, `[127.0.0.1]:${sshPort} ${hostKey}\n`, { mode: 0o600 });
  const gitEnv = { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_SSH_COMMAND: `ssh -F /dev/null -i '${key}' -o IdentityAgent=none -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile='${known}'` };
  const checkout = path.join(temporary, 'checkout');
  fs.mkdirSync(checkout);
  const git = args => execFileSync('git', ['-C', checkout, ...args], { env: gitEnv, encoding: 'utf8' }).trim();
  git(['init', '-b', 'main']);
  git(['config', 'user.name', 'Collaboration Test']);
  git(['config', 'user.email', 'test@example.com']);
  fs.writeFileSync(path.join(checkout, 'README.md'), '# Collaboration test\n');
  git(['add', '.']);
  git(['commit', '-m', 'Initial repository']);
  compose(['exec', '-T', '--user', 'git', 'web', 'moonhub', 'repo-create', 'engineering/service']);
  git(['remote', 'add', 'origin', `ssh://git@127.0.0.1:${sshPort}/engineering/service.git`]);
  git(['push', '-u', 'origin', 'main']);
  const initial = git(['rev-parse', 'HEAD']);
  git(['checkout', '-b', 'feature/retry']);
  fs.writeFileSync(path.join(checkout, 'retry.mbt'), 'fn retry_count() -> Int { 3 }\n');
  git(['add', '.']);
  git(['commit', '-m', 'Add bounded retry']);
  git(['push', '-u', 'origin', 'feature/retry']);

  await owner.goto(base + '/engineering/service/issues/new');
  await owner.getByLabel('Title', { exact: true }).fill('Retry failed imports without losing work');
  await owner.getByLabel('Description', { exact: true }).fill('Track recoverable import failures and verify bounded retries.');
  await owner.getByLabel('Assignee', { exact: true }).selectOption({ label: 'Reviewer (@reviewer)' });
  await capture(owner, 'issue-new');
  await owner.getByRole('button', { name: 'Create issue', exact: true }).click();
  await owner.waitForURL(base + '/engineering/service/issues/1');
  await owner.getByLabel('Comment', { exact: true }).fill('This change needs a reviewed merge request.');
  await owner.getByRole('button', { name: 'Add comment', exact: true }).click();
  await capture(owner, 'issue-detail');
  await owner.getByRole('link', { name: 'Create merge request', exact: true }).click();
  assert.equal(await owner.getByLabel('Related issue number (optional)', { exact: true }).inputValue(), '1');
  await owner.getByLabel('Title', { exact: true }).fill('Add bounded retries for repository imports');
  await owner.getByLabel('Description', { exact: true }).fill('Implements the retry behavior tracked in the linked issue.');
  await owner.getByLabel('Source branch', { exact: true }).selectOption('feature/retry');
  await owner.getByLabel('Target branch', { exact: true }).selectOption('main');
  await capture(owner, 'mr-new');
  await owner.getByRole('button', { name: 'Create merge request', exact: true }).click();
  await owner.waitForURL(base + '/engineering/service/merge-requests/1');
  await owner.goto(base + '/engineering/service/settings/branches');
  await owner.getByLabel('Branch name', { exact: true }).fill('main');
  await owner.getByRole('button', { name: 'Protect branch', exact: true }).click();
  await capture(owner, 'branch-protection');
  const rejected = spawnSync('git', ['-C', checkout, 'push', 'origin', 'HEAD:main'], { env: gitEnv, encoding: 'utf8' });
  assert.notEqual(rejected.status, 0, 'protected branch accepted direct push');
  assert.match(rejected.stderr, /protected/);
  const internal = spawnSync('git', ['-C', checkout, 'push', 'origin', 'HEAD:refs/moonhub/merges/999'], { env: gitEnv, encoding: 'utf8' });
  assert.notEqual(internal.status, 0, 'internal ref accepted client update');

  const mrUrl = base + '/engineering/service/merge-requests/1';
  await reviewer.goto(mrUrl);
  await reviewer.getByLabel('Review', { exact: true }).selectOption('approved');
  await reviewer.getByLabel('Comment', { exact: true }).fill('Approved version one.');
  await reviewer.getByRole('button', { name: 'Submit review', exact: true }).click();
  fs.writeFileSync(path.join(checkout, 'retry.mbt'), 'fn retry_count() -> Int { 4 }\n');
  git(['add', '.']);
  git(['commit', '-m', 'Adjust retry policy']);
  git(['push']);
  const source = git(['rev-parse', 'HEAD']);
  await owner.goto(mrUrl);
  await owner.getByText('Outdated', { exact: true }).waitFor();
  assert.equal(await owner.getByRole('button', { name: 'Merge request', exact: true }).count(), 0);
  await reviewer.goto(mrUrl + '?tab=changes');
  await reviewer.locator('moonhub-commit-diff').waitFor();
  await reviewer.waitForFunction(() => document.querySelector('moonhub-commit-diff pre[data-patch]')?.hidden);
  await capture(reviewer, 'mr-changes');
  await reviewer.goto(mrUrl);
  await reviewer.getByLabel('Review', { exact: true }).selectOption('approved');
  await reviewer.getByLabel('Comment', { exact: true }).fill('Reviewed the updated commit.');
  await reviewer.getByRole('button', { name: 'Submit review', exact: true }).click();
  await owner.goto(mrUrl);
  await capture(owner, 'mr-reviewed');
  await owner.getByRole('button', { name: 'Merge request', exact: true }).click();
  for (let i = 0; i < 40; i++) {
    await owner.goto(mrUrl);
    if (await owner.getByText('Merged as', { exact: false }).count()) break;
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  await owner.getByText('Merged as', { exact: false }).waitFor();
  await capture(owner, 'mr-merged');
  git(['fetch', 'origin']);
  assert.equal(git(['show', '-s', '--format=%P', 'origin/main']), `${initial} ${source}`);
  assert(!git(['ls-remote', 'origin']).includes('refs/moonhub/'));
  await owner.goto(base + '/engineering/service/issues/1');
  await owner.getByRole('heading', { name: 'Related merge requests', exact: true }).waitFor();
  await owner.getByRole('button', { name: 'Close issue', exact: true }).click();
  await owner.getByRole('button', { name: 'Reopen issue', exact: true }).waitFor();
  await capture(owner, 'issue-closed');
  await owner.getByRole('button', { name: 'Reopen issue', exact: true }).click();
  await owner.getByRole('button', { name: 'Close issue', exact: true }).waitFor();
  assert.deepEqual(errors, []);
  console.log('Collaboration smoke passed: issue assignment/discussion/transitions, MR linking, stale approvals, two-user review, protected/internal SSH refs, merge commit, desktop/mobile layouts.');
}

main().catch(error => {
  console.error(error);
  try { console.error(compose(['logs', '--tail', '100', '--no-color'])); } catch {}
  process.exitCode = 1;
}).finally(async () => {
  if (browser) await browser.close();
  try { compose(['down', '--volumes', '--remove-orphans']); } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
});
