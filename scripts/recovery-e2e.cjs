// Real offline restore/rollback drill. Existing preview projects are untouched.
// Artifacts and the recovered project are retained for operator acceptance.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync, spawn } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const project = `moonhub-recovery-${Date.now()}`;
const output = path.join(root, 'backups', project);
fs.mkdirSync(output, { recursive: true, mode: 0o700 });
fs.mkdirSync(path.join(output, 'imports'));
const password = crypto.randomBytes(24).toString('hex');
fs.writeFileSync(path.join(output, 'password'), password, { mode: 0o600 });
fs.writeFileSync(path.join(output, 'provider-token'), crypto.randomBytes(32).toString('hex'), { mode: 0o600 });
const sourcePort = process.env.MOONHUB_RECOVERY_SOURCE_PORT || '18084';
const sourceSsh = process.env.MOONHUB_RECOVERY_SOURCE_SSH || '12226';
const targetPort = process.env.MOONHUB_RECOVERY_TARGET_PORT || '18085';
const targetSsh = process.env.MOONHUB_RECOVERY_TARGET_SSH || '12227';
const targetProject = project + '-restored';
const settings = {
  MOONHUB_COMPOSE_PROJECT_NAME: project, MOONHUB_ENABLE_PIPELINES: '1', MOONHUB_BUILD_IMAGES: '0',
  MOONHUB_IMAGE: process.env.MOONHUB_IMAGE || 'moonhub:acceptance',
  MOONHUB_PROVIDER_IMAGE: process.env.MOONHUB_PROVIDER_IMAGE || 'moonhub-provider:acceptance',
  MOONHUB_RUNNER_IMAGE: process.env.MOONHUB_RUNNER_IMAGE || 'moonhub-runner:acceptance',
  MOONHUB_HTTP_PORT: sourcePort, MOONHUB_SSH_PORT: sourceSsh, MOONHUB_SSH_BIND: '127.0.0.1',
  MOONHUB_ROOT_PASSWORD_FILE: path.join(output, 'password'), MOONHUB_PROVIDER_TOKEN_FILE: path.join(output, 'provider-token'),
  MOONHUB_SSH_IMPORT_DIR: path.join(output, 'imports'), MOONHUB_PROVIDER_REPOSITORIES: 'root/recovery',
  MOONHUB_PIPELINE_NETWORK: project + '_pipeline', MOONHUB_PIPELINE_PREFIX: process.env.MOONHUB_RECOVERY_SOURCE_PREFIX || '172.30.94',
  MOONHUB_BACKUP_DIR: path.join(output, 'snapshots'), MOONHUB_RECOVERY_STATE_DIR: path.join(output, 'recovered'),
  MOONHUB_DEPLOY_LOCK_DIR: path.join(output, 'deploy.lock'),
};
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
const settingsFile = path.join(output, 'deploy.env');
fs.writeFileSync(settingsFile, Object.entries(settings).map(([k, v]) => `${k}=${quote(v)}`).join('\n') + '\n', { mode: 0o600 });
const env = { ...process.env, ...settings, MOONHUB_DEPLOY_ENV_FILE: settingsFile };
const run = (cmd, args, options = {}) => execFileSync(cmd, args, { cwd: root, env, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 180000, ...options }).trim();
const long = (cmd, args, options = {}) => new Promise((resolve, reject) => {
  const child = spawn(cmd, args, { cwd: root, env, stdio: 'inherit', ...options });
  const timer = setTimeout(() => child.kill('SIGTERM'), 600000);
  child.once('error', reject);
  child.once('close', code => { clearTimeout(timer); code === 0 ? resolve() : reject(new Error(`${cmd} exited ${code}`)); });
});
const composeArgs = ['compose', '--env-file', '/dev/null', '-p', project, '-f', 'compose.yaml', '-f', 'deploy/compose.pipeline.yaml'];
const compose = (args, options) => run('docker', [...composeArgs, ...args], options);
const csrf = html => { const token = html.match(/name="csrf_token" value="([a-f0-9]+)"/); assert.ok(token); return token[1]; };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
let base = `http://127.0.0.1:${sourcePort}`, cookie = '';
async function http(route, fields) {
  const response = await fetch(base + route, { method: fields ? 'POST' : 'GET', redirect: 'manual', signal: AbortSignal.timeout(15000),
    headers: { ...(cookie ? { Cookie: cookie } : {}), ...(fields ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}) },
    body: fields ? new URLSearchParams(fields) : undefined });
  if (response.headers.get('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
  return { status: response.status, location: response.headers.get('location'), body: await response.text() };
}
async function login() { cookie = ''; assert.equal((await http('/-/login', { name_key: 'root', password })).status, 303); }
async function pipeline() {
  const form = await http('/root/recovery/pipelines/new');
  const started = await http('/root/recovery/pipelines', { csrf_token: csrf(form.body), branch: 'main', workflow: '.github/workflows/check.yml' });
  assert.equal(started.status, 303);
  for (let i = 0; i < 120; i++) {
    const page = await http(started.location);
    const state = page.body.match(/data-state="([^"]+)"/)?.[1];
    if (state === 'success') { assert.ok(page.body.includes('RECOVERY_JOB_OK')); return started.location; }
    assert.ok(!['failure', 'timed_out', 'lost'].includes(state), `pipeline ${state}`);
    await delay(1000);
  }
  throw new Error('pipeline did not finish');
}
async function main() {
  console.log(`Recovery drill artifacts: ${output}`);
  compose(['up', '-d', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '180', 'web', 'ssh', 'pipeline-docker']);
  await login();
  assert.equal((await http('/-/change-password', { new_password: password, confirm_password: password })).status, 303);
  const web = compose(['ps', '-q', 'web']);
  const dind = compose(['ps', '-q', 'pipeline-docker']);
  const sourceImage = run('docker', ['inspect', '-f', '{{.Image}}', web]);
  compose(['exec', '-T', '--user', 'git', 'web', 'moonhub', 'repo-create', 'root/recovery']);
  const key = path.join(output, 'client');
  run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', key]);
  compose(['exec', '-T', '--user', 'git', 'web', 'moonhub', 'ssh-key-add', 'root', '--title', 'Recovery drill'], { input: fs.readFileSync(key + '.pub') });
  const hostKey = compose(['exec', '-T', 'ssh', 'cat', '/var/lib/moonhub/ssh/ssh_host_ed25519_key.pub']).split(/\s+/).slice(0, 2).join(' ');
  const known = path.join(output, 'known_hosts');
  fs.writeFileSync(known, [sourceSsh, targetSsh].map(port => `[127.0.0.1]:${port} ${hostKey}\n`).join(''), { mode: 0o600 });
  const gitEnv = { ...env, GIT_TERMINAL_PROMPT: '0', GIT_SSH_COMMAND: `ssh -F /dev/null -i ${quote(key)} -o IdentityAgent=none -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${quote(known)}` };
  const checkout = path.join(output, 'checkout');
  fs.mkdirSync(path.join(checkout, '.github/workflows'), { recursive: true });
  fs.writeFileSync(path.join(checkout, 'README.md'), '# Recovery acceptance\n');
  fs.writeFileSync(path.join(checkout, 'binary.bin'), Buffer.from([0, 1, 255, 13, 10]));
  fs.writeFileSync(path.join(checkout, '.github/workflows/check.yml'), 'name: Recovery check\non: workflow_dispatch\njobs:\n  check:\n    runs-on: [self-hosted, linux]\n    steps:\n      - run: test -f README.md && echo RECOVERY_JOB_OK\n');
  const git = args => run('git', ['-C', checkout, ...args], { env: gitEnv });
  git(['init', '-b', 'main']);
  git(['config', 'user.name', 'Recovery']); git(['config', 'user.email', 'recovery@example.invalid']);
  git(['add', '.']); git(['-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'Recovery seed']);
  const commit = git(['rev-parse', 'HEAD']);
  git(['remote', 'add', 'origin', `ssh://git@127.0.0.1:${sourceSsh}/root/recovery.git`]); git(['push', 'origin', 'main']);
  git(['checkout', '-b', 'feature']); fs.writeFileSync(path.join(checkout, 'feature.txt'), 'Retain the merge request\n');
  git(['add', '.']); git(['-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'Feature']); git(['push', 'origin', 'feature']);
  const form = await http('/root/recovery/merge-requests/new');
  const mr = await http('/root/recovery/merge-requests', { csrf_token: csrf(form.body), title: 'Recover this MR', description: 'Durable collaboration state', source: 'feature', target: 'main' });
  assert.equal(mr.status, 303);
  const imageTar = path.join(output, 'runner.tar');
  run('docker', ['save', '-o', imageTar, settings.MOONHUB_RUNNER_IMAGE]);
  const imageFd = fs.openSync(imageTar, 'r');
  try { run('docker', ['exec', '-i', dind, 'docker', '-H', 'unix:///run/moonhub-docker/docker.sock', 'load'], { stdio: [imageFd, 'pipe', 'pipe'] }); }
  finally { fs.closeSync(imageFd); }
  fs.unlinkSync(imageTar);
  compose(['exec', '-T', '--user', 'git', 'web', 'sh', '-eu', '-c',
    'umask 077; token=$(mktemp); trap \'rm -f "$token"\' EXIT; cat > "$token"; moonhub pipeline-provider-ensure --name dind --token-file "$token" --labels self-hosted,linux --repositories root/recovery --admin root'],
  { input: fs.readFileSync(settings.MOONHUB_PROVIDER_TOKEN_FILE) });
  compose(['up', '-d', '--no-build', '--pull', 'never', 'pipeline-provider']);
  const pipelineRoute = await pipeline();
  await delay(1500);
  compose(['stop', 'pipeline-provider', 'web', 'ssh']);
  await long('bash', ['deploy/deploy.sh', 'backup']);
  const bundle = path.join(settings.MOONHUB_BACKUP_DIR, fs.readdirSync(settings.MOONHUB_BACKUP_DIR).find(name => !name.startsWith('.')));
  compose(['stop', 'pipeline-docker']);
  // No checkout, Git, source service or registry is used by this entry point.
  await long('bash', [path.join(bundle, 'recovery.sh'), 'restore', bundle, '--project', targetProject,
    '--http-port', targetPort, '--ssh-port', targetSsh, '--pipeline-prefix', process.env.MOONHUB_RECOVERY_TARGET_PREFIX || '172.30.95'], { cwd: output });
  const state = path.join(settings.MOONHUB_RECOVERY_STATE_DIR, fs.readdirSync(settings.MOONHUB_RECOVERY_STATE_DIR)[0]);
  const recoveredArgs = ['compose', '--env-file', '/dev/null', '-p', targetProject, '-f', path.join(state, 'compose.json')];
  const recovered = args => run('docker', [...recoveredArgs, ...args]);
  base = `http://127.0.0.1:${targetPort}`;
  await login();
  for (const [route, text] of [['/root/recovery', 'README.md'], ['/root/recovery/commits', commit.slice(0, 12)], [mr.location, 'Recover this MR'], [pipelineRoute, 'RECOVERY_JOB_OK']]) {
    const page = await http(route); assert.equal(page.status, 200); assert.ok(page.body.includes(text), route);
  }
  assert.equal(run('docker', ['inspect', '-f', '{{.Image}}', recovered(['ps', '-q', 'web'])]), sourceImage);
  const cloned = path.join(output, 'cloned');
  run('git', ['clone', `ssh://git@127.0.0.1:${targetSsh}/root/recovery.git`, cloned], { env: gitEnv });
  assert.equal(run('git', ['-C', cloned, 'rev-parse', 'HEAD']), commit);
  assert.deepEqual(fs.readFileSync(path.join(cloned, 'binary.bin')), Buffer.from([0, 1, 255, 13, 10]));
  const newRun = await pipeline();
  // Corrupt copies must fail before stop; no image archives need duplicating.
  const corrupt = path.join(output, 'corrupt');
  fs.mkdirSync(corrupt);
  for (const file of fs.readdirSync(bundle)) {
    const source = path.join(bundle, file), target = path.join(corrupt, file);
    if (fs.statSync(source).isDirectory()) fs.cpSync(source, target, { recursive: true });
    else fs.linkSync(source, target);
  }
  fs.unlinkSync(path.join(corrupt, 'data.tar')); fs.writeFileSync(path.join(corrupt, 'data.tar'), 'corrupt');
  const before = recovered(['ps', '-q', 'web']);
  await assert.rejects(long('bash', [path.join(bundle, 'recovery.sh'), 'restore', corrupt, '--replace', '--project', targetProject,
    '--http-port', targetPort, '--ssh-port', targetSsh, '--pipeline-prefix', process.env.MOONHUB_RECOVERY_TARGET_PREFIX || '172.30.95'], { cwd: output }));
  assert.equal(recovered(['ps', '-q', 'web']), before);
  await delay(1500);
  await long('bash', [path.join(bundle, 'recovery.sh'), 'restore', bundle, '--replace', '--project', targetProject,
    '--http-port', targetPort, '--ssh-port', targetSsh, '--pipeline-prefix', process.env.MOONHUB_RECOVERY_TARGET_PREFIX || '172.30.95'], { cwd: output });
  await login();
  assert.equal((await http(newRun)).status, 404, 'rollback retained data newer than the snapshot');
  assert.ok((await http(pipelineRoute)).body.includes('RECOVERY_JOB_OK'));
  assert.ok(fs.readdirSync(settings.MOONHUB_BACKUP_DIR).filter(name => !name.startsWith('.')).length >= 2, 'no pre-restore protection backup');
  const finalState = path.join(settings.MOONHUB_RECOVERY_STATE_DIR, fs.readdirSync(settings.MOONHUB_RECOVERY_STATE_DIR).sort().at(-1));
  const upgradeConfig = JSON.parse(run('bash', ['-c', 'set -a; . "$1"; docker compose --env-file /dev/null -p "$MOONHUB_COMPOSE_PROJECT_NAME" -f compose.yaml -f deploy/compose.pipeline.yaml config --format json',
    'recovery-upgrade-config', path.join(finalState, 'upgrade.env')], { env: { ...env, MOONHUB_RUNNER_IMAGE: settings.MOONHUB_RUNNER_IMAGE } }));
  const restoredConfig = JSON.parse(fs.readFileSync(path.join(finalState, 'compose.json')));
  for (const [key, volume] of Object.entries(restoredConfig.volumes)) assert.equal(upgradeConfig.volumes[key].name, volume.name);
  const receipt = { project: targetProject, base, repository: base + '/root/recovery', pipeline: base + pipelineRoute,
    mergeRequest: base + mr.location, sourceImage, commit, bundle, state: finalState,
    passwordFile: settings.MOONHUB_ROOT_PASSWORD_FILE,
    checks: ['offline restore', 'pinned image', 'login', 'files and commits', 'MR', 'pipeline history', 'new DinD job', 'SSH clone and original host key', 'binary bytes', 'corruption rejection', 'replace protection backup', 'data rollback', 'future upgrade volume names'] };
  fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(receipt, null, 2), { mode: 0o600 });
  console.log(JSON.stringify(receipt, null, 2));
  console.log('Source project stopped; recovered project retained. No existing previews were changed.');
}
main().catch(error => { console.error(error); console.error(`Failed drill retained at ${output}`); process.exitCode = 1; });
