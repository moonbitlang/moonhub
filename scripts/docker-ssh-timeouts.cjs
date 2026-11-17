// Called by docker-smoke.sh against its disposable, authenticated SSH fixture.
const assert = require('node:assert/strict');
const { spawn, execFileSync } = require('node:child_process');

const [mode, idle, maximum, port, key, knownHosts, docker, ...compose] = process.argv.slice(2);
assert.ok(['idle', 'maximum'].includes(mode));
const variables = ['MOONHUB_SSH_READ_IDLE_TIMEOUT_SECONDS', 'MOONHUB_SSH_READ_MAX_SECONDS'];
const ssh = spawn('ssh', ['-F', '/dev/null', '-i', key, '-p', port,
  '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
  '-o', `UserKnownHostsFile=${knownHosts}`,
  ...variables.flatMap(name => ['-o', `SendEnv=${name}`, '-o', `SetEnv=${name}=2147483`]),
  'git@127.0.0.1', "git-upload-pack 'root/demo.git'"], {
  env: { ...process.env, ...Object.fromEntries(variables.map(name => [name, '2147483'])) },
  stdio: ['pipe', 'pipe', 'pipe'],
});
let stdout = '', stderr = '';
ssh.stdout.on('data', chunk => { stdout += chunk; });
ssh.stderr.on('data', chunk => { stderr += chunk; });
const done = new Promise((resolve, reject) => { ssh.once('error', reject); ssh.once('close', resolve); });
const watchdog = setTimeout(() => ssh.kill('SIGKILL'), 15000);
async function main() {
  await new Promise((resolve, reject) => {
    ssh.stdout.on('data', () => { if (stdout.includes('refs/heads/main')) resolve(); });
    ssh.once('error', reject);
    ssh.once('close', () => reject(new Error(`SSH exited before advertising refs: ${stderr}`)));
  });
  // Inspect only the two limit variables in the actual forced-command session,
  // and Git's argv. Do not expose unrelated session environment values.
  const inspect = `const fs = require('node:fs');
const sessions = [], git = [];
for (const pid of fs.readdirSync('/proc').filter(name => /^[0-9]+$/.test(name))) {
  try {
    const args = fs.readFileSync('/proc/' + pid + '/cmdline', 'utf8').split(String.fromCharCode(0)).filter(Boolean);
    if (args[0]?.endsWith('/moonhub') && args[1] === 'ssh-serve') {
      const env = Object.fromEntries(fs.readFileSync('/proc/' + pid + '/environ', 'utf8')
        .split(String.fromCharCode(0)).filter(item => item.includes('='))
        .map(item => [item.slice(0, item.indexOf('=')), item.slice(item.indexOf('=') + 1)]));
      sessions.push(Object.fromEntries(${JSON.stringify(variables)}.map(name => [name, env[name]])));
    }
    if (args.includes('upload-pack') || args[0]?.endsWith('/git-upload-pack')) git.push(args);
  } catch (error) { if (!['ENOENT', 'ESRCH'].includes(error.code)) throw error; }
}
console.log(JSON.stringify({ sessions, git }));`;
  const state = JSON.parse(execFileSync(docker, [...compose, 'exec', '-T', '--user', 'git', 'ssh', 'node', '-e', inspect],
    { encoding: 'utf8', timeout: 10000 }));
  assert.deepEqual(state.sessions, [{ [variables[0]]: idle, [variables[1]]: maximum }], 'client overrode trusted session limits');
  assert.ok(state.git.some(args => args.includes(`--timeout=${idle}`)), 'idle setting did not reach upload-pack');
  assert.notEqual(await done, 0, 'stalled read succeeded');
  assert.equal(ssh.signalCode, null, 'read exceeded the smoke watchdog');
  if (mode === 'maximum') assert.match(stderr, /SSH read exceeded its maximum duration/);
  // Git may exit on SIGALRM without printing a diagnostic for its idle timeout.
  // The watchdog is shorter than the configured total limit in this case.
  else assert.doesNotMatch(stderr, /maximum duration/);
  assert.doesNotMatch(stdout, /moonhub:|maximum duration|fatal:/);
  console.log(`Docker SSH ${mode} limit passed; client environment overrides rejected.`);
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  clearTimeout(watchdog);
  ssh.kill('SIGTERM');
  ssh.stdin.destroy();
  await done;
});
