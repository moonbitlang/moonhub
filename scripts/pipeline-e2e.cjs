// Disposable real-DinD acceptance. Builds are separate; successful runs keep
// their isolated project for inspection and write exact connection settings.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync, spawn } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const project = `moonhub-acceptance-${Date.now()}`;
const output = path.join(root, '_build', project);
fs.mkdirSync(output, { recursive: true, mode: 0o700 });
fs.mkdirSync(path.join(output, 'imports'));
const password = crypto.randomBytes(24).toString('hex');
const token = crypto.randomBytes(32).toString('hex');
fs.writeFileSync(path.join(output, 'root-password'), password, { mode: 0o600 });
fs.writeFileSync(path.join(output, 'provider-token'), token, { mode: 0o600 });
const settings = {
  MOONHUB_COMPOSE_PROJECT_NAME: project, MOONHUB_ENABLE_PIPELINES: '1', MOONHUB_BUILD_IMAGES: '0',
  MOONHUB_IMAGE: process.env.MOONHUB_IMAGE || 'moonhub:acceptance',
  MOONHUB_PROVIDER_IMAGE: process.env.MOONHUB_PROVIDER_IMAGE || 'moonhub-provider:acceptance',
  MOONHUB_RUNNER_IMAGE: process.env.MOONHUB_RUNNER_IMAGE || 'moonhub-runner:acceptance',
  MOONHUB_HTTP_PORT: process.env.MOONHUB_E2E_HTTP_PORT || '18082',
  MOONHUB_SSH_PORT: process.env.MOONHUB_E2E_SSH_PORT || '12224', MOONHUB_SSH_BIND: '127.0.0.1',
  MOONHUB_PIPELINE_NETWORK: project + '_pipeline', MOONHUB_PIPELINE_PREFIX: process.env.MOONHUB_E2E_PREFIX || '172.30.91',
  MOONHUB_ROOT_PASSWORD_FILE: path.join(output, 'root-password'),
  MOONHUB_PROVIDER_TOKEN_FILE: path.join(output, 'provider-token'), MOONHUB_PROVIDER_REPOSITORIES: 'root/demo',
  MOONHUB_SSH_IMPORT_DIR: path.join(output, 'imports'), MOONHUB_BACKUP_DIR: path.join(output, 'backups'),
  MOONHUB_DEPLOY_LOCK_DIR: path.join(output, 'deploy.lock'),
};
const envFile = path.join(output, 'deploy.env');
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
fs.writeFileSync(envFile, Object.entries(settings).map(([key, value]) => `${key}=${quote(value)}`).join('\n') + '\n', { mode: 0o600 });
const env = { ...process.env, ...settings, MOONHUB_DEPLOY_ENV_FILE: envFile };
const composeArgs = ['compose', '--env-file', '/dev/null', '-p', project, '-f', 'compose.yaml', '-f', 'deploy/compose.pipeline.yaml'];
const run = (cmd, args, options = {}) => execFileSync(cmd, args, { cwd: root, env, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 180000, ...options });
const compose = args => run('docker', [...composeArgs, ...args]).trim();
const base = 'http://127.0.0.1:' + settings.MOONHUB_HTTP_PORT;
let cookie = '';
async function http(route, fields) {
  const response = await fetch(base + route, {
    method: fields ? 'POST' : 'GET', redirect: 'manual', signal: AbortSignal.timeout(15000),
    headers: { ...(cookie ? { Cookie: cookie } : {}), ...(fields ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}) },
    body: fields ? new URLSearchParams(fields) : undefined,
  });
  const set = response.headers.get('set-cookie');
  if (set) cookie = set.split(';')[0];
  return { code: response.status, location: response.headers.get('location'), body: await response.text() };
}
const csrf = html => { const found = html.match(/name="csrf_token" value="([a-f0-9]+)"/); assert.ok(found, 'missing CSRF token'); return found[1]; };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
let web, dind;
const inner = args => run('docker', ['exec', dind, 'docker', '-H', 'unix:///run/moonhub-docker/docker.sock', ...args]).trim();
function git(args, input) {
  return run('docker', ['exec', '-i', '--user', 'git', web, 'git', '--git-dir=/data/repos/root/demo.git',
    '-c', 'user.name=Acceptance', '-c', 'user.email=acceptance@example.invalid', ...args], { input }).trim();
}
function seed(cancel = false) {
  const script = [
    'test "$(id -u)" = 10001', 'test "$PPID" = 1', 'test ! -d .git',
    'test ! -e /var/run/docker.sock', 'test ! -e /run/moonhub-docker/docker.sock', 'test ! -e /data/moonhub.db',
    'test ! -e /run/secrets/provider_token', 'test -z "${DOCKER_HOST:-}"',
    'if cat /proc/1/environ >/dev/null 2>&1; then exit 90; fi',
    `if curl --noproxy '*' -fsS --max-time 2 http://${settings.MOONHUB_PIPELINE_PREFIX}.11:2375/_ping; then exit 91; fi`,
    'grep -qx pinned-original README.md', 'test -x verify.sh', './verify.sh',
    'test "$(od -An -tx1 binary.dat | tr -d " \\n")" = 00ff8041',
    'moon run --strip -j 1 .',
    'printf "CHECKOUT_OK:%s\\n" "$GITHUB_SHA"',
    cancel ? 'sleep 90' : 'sleep 6',
  ];
  const workflow = ['name: Pinned checkout', 'on: workflow_dispatch', 'jobs:', '  build:',
    '    runs-on: [self-hosted, linux]', '    timeout-minutes: 2', '    steps:', '      - id: verify', '        shell: bash',
    '        run: |', ...script.map(line => '          ' + line), ''].join('\n');
  const blob = input => git(['hash-object', '-w', '--stdin'], input);
  const workflows = git(['mktree'], `100644 blob ${blob(workflow)}\tbuild.yml\n`);
  const github = git(['mktree'], `040000 tree ${workflows}\tworkflows\n`);
  const entries = [
    `040000 tree ${github}\t.github`,
    `100644 blob ${blob('pinned-original\n')}\tREADME.md`,
    `100644 blob ${blob(Buffer.from([0, 255, 128, 65]))}\tbinary.dat`,
    `100755 blob ${blob('#!/bin/sh\nset -eu\nprintf "EXECUTABLE_OK\\n"\n')}\tverify.sh`,
    `100644 blob ${blob('name = "test/acceptance"\npreferred_target = "native"\n')}\tmoon.mod`,
    `100644 blob ${blob('pkgtype(kind: "executable")\n')}\tmoon.pkg`,
    `100644 blob ${blob('fn main { println("NATIVE_OK") }\n')}\tmain.mbt`,
  ];
  const tree = git(['mktree'], entries.join('\n') + '\n');
  const sha = git(['commit-tree', tree, '-m', 'Pinned checkout acceptance']);
  git(['update-ref', 'refs/heads/pipeline', sha]);
  return sha;
}
async function setPaused(value) {
  const page = await http('/-/admin/pipelines/providers'); assert.equal(page.code, 200);
  const result = await http('/-/admin/pipelines/providers/1/pause', { csrf_token: csrf(page.body), paused: String(value) });
  assert.equal(result.code, 303);
}
async function dispatch() {
  const form = await http('/root/demo/pipelines/new'); assert.equal(form.code, 200);
  const created = await http('/root/demo/pipelines', { csrf_token: csrf(form.body), branch: 'pipeline', workflow: '.github/workflows/build.yml' });
  assert.equal(created.code, 303);
  assert.match(created.location, /^\/root\/demo\/pipelines\/\d+$/);
  return created.location;
}
async function waitRun(route, wanted) {
  for (let i = 0; i < 80; i++) {
    const page = await http(route); assert.equal(page.code, 200);
    if (page.body.includes(`data-state="${wanted}"`)) return page;
    if (/data-state="(?:failure|lost|timed_out)"/.test(page.body)) throw new Error(`Run failed: ${route}`);
    await delay(1000);
  }
  throw new Error(`Run did not reach ${wanted}: ${route}`);
}
async function upgrade() {
  await new Promise((resolve, reject) => {
    const child = spawn('bash', ['deploy/deploy.sh', 'upgrade'], { cwd: root, env, stdio: 'inherit' });
    child.once('error', reject); child.once('close', code => code === 0 ? resolve() : reject(new Error(`upgrade exit ${code}`)));
  });
  web = compose(['ps', '-q', 'web']); dind = compose(['ps', '-q', 'pipeline-docker']);
}
async function main() {
  for (const image of [settings.MOONHUB_IMAGE, settings.MOONHUB_PROVIDER_IMAGE, settings.MOONHUB_RUNNER_IMAGE]) run('docker', ['image', 'inspect', image]);
  compose(['up', '-d', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '180', 'web', 'ssh', 'pipeline-docker']);
  web = compose(['ps', '-q', 'web']);
  assert.equal((await http('/-/login', { name_key: 'root', password })).code, 303);
  assert.equal((await http('/-/change-password', { new_password: password, confirm_password: password })).code, 303);
  compose(['exec', '-T', '--user', 'git', 'web', 'moonhub', 'repo-create', 'root/demo']);
  await upgrade();
  const backups = fs.readdirSync(settings.MOONHUB_BACKUP_DIR);
  assert.ok(backups.some(dir => fs.existsSync(path.join(settings.MOONHUB_BACKUP_DIR, dir, 'data/moonhub.db'))));
  assert.ok(backups.some(dir => fs.existsSync(path.join(settings.MOONHUB_BACKUP_DIR, dir, 'ssh-host-keys/ssh_host_ed25519_key'))));
  await setPaused(1);
  const sha = seed();
  const route = await dispatch();
  // Replace the branch tree after dispatch, before the provider can claim.
  const replacement = git(['mktree'], `100644 blob ${git(['hash-object', '-w', '--stdin'], 'wrong-version\n')}\tREADME.md\n`);
  git(['update-ref', 'refs/heads/pipeline', git(['commit-tree', replacement, '-m', 'Force push after dispatch'])]);
  await setPaused(0);
  let checkedContainer = false;
  for (let i = 0; i < 40; i++) {
    const ids = inner(['ps', '-q']);
    if (ids) {
      const inspect = JSON.parse(inner(['inspect', ids.split('\n')[0]]))[0];
      assert.equal(inspect.Config.OpenStdin, true);
      assert.equal(inspect.HostConfig.Privileged, false);
      assert.equal(inspect.HostConfig.NetworkMode, 'bridge');
      assert.equal(inspect.HostConfig.ReadonlyRootfs, true);
      assert.ok(inspect.HostConfig.CapDrop.includes('ALL'));
      assert.deepEqual(inspect.Mounts.filter(m => m.Type === 'bind').map(m => m.Destination), ['/control/assignment.json']);
      checkedContainer = true; break;
    }
    await delay(250);
  }
  assert.ok(checkedContainer, 'did not observe the real Runner');
  const done = await waitRun(route, 'success');
  assert.ok(done.body.includes(`CHECKOUT_OK:${sha}`));
  assert.ok(done.body.includes('NATIVE_OK'));
  assert.ok(done.body.includes('EXECUTABLE_OK'));
  assert.ok(!done.body.includes(token));
  await delay(1000);
  assert.equal(inner(['ps', '-aq']), '', 'Runner was not removed');
  seed(true);
  const cancelled = await dispatch();
  for (let i = 0; i < 40; i++) {
    const page = await http(cancelled);
    if (page.body.includes('CHECKOUT_OK:')) break;
    await delay(500);
    if (i === 39) throw new Error('cancel fixture never started');
  }
  const page = await http(cancelled);
  assert.equal((await http(cancelled + '/cancel', { csrf_token: csrf(page.body) })).code, 303);
  await waitRun(cancelled, 'cancelled');
  await delay(1000);
  assert.equal(inner(['ps', '-aq']), '', 'cancelled Runner was not removed');
  await upgrade();
  const providers = await http('/-/admin/pipelines/providers');
  assert.equal((providers.body.match(/<strong>dind<\/strong>/g) || []).length, 1, 'ensure duplicated provider');
  assert.ok((await http(route)).body.includes(`CHECKOUT_OK:${sha}`));
  const receipt = { project, base, run: base + route, commit: sha, checks: ['pinned checkout', 'binary and executable files', 'native build', 'Docker API inaccessible', 'cancellation', 'container cleanup', 'stopped backups', 'repeat upgrade and ensure'] };
  fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(receipt, null, 2));
  console.log(JSON.stringify(receipt, null, 2));
  console.log(`Deployment settings retained at ${envFile}`);
}
main().catch(error => {
  console.error(error.message);
  console.error(`Failed environment retained for diagnosis: ${envFile}`);
  process.exitCode = 1;
});
