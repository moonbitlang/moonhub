const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-provider-smoke-'));
const binary = path.resolve('_build/native/debug/build/moonhub.exe');
const providerToken = 'a'.repeat(64);
const attemptTokenFile = path.join(root, 'attempt-token');
const dockerArgsFile = path.join(root, 'docker-args');
const cleanupFile = path.join(root, 'cleanup');
const dockerCalledFile = path.join(root, 'docker-called');
const fakeDocker = path.join(root, 'docker');
const tokenFile = path.join(root, 'provider-token');
const workspace = path.join(root, 'workspace');
fs.mkdirSync(workspace);
fs.writeFileSync(tokenFile, providerToken, { mode: 0o600 });
fs.writeFileSync(fakeDocker, `#!/bin/sh
set -eu
touch ${JSON.stringify(dockerCalledFile)}
if [ "$1" = info ]; then exit 0; fi
if [ "$1" = image ] && [ "$2" = inspect ]; then exit 0; fi
if [ "$1" = ps ]; then printf '%s\\n' deadbeef; exit 0; fi
if [ "$1" = run ]; then
  printf '%s\\n' "$*" > ${JSON.stringify(dockerArgsFile)}
  IFS= read -r token
  printf '%s' "$token" > ${JSON.stringify(attemptTokenFile)}
  test "$(printf '%s' "$token" | wc -c | tr -d ' ')" = 64
  case "$*" in *--privileged*) exit 91;; esac
  printf '%s\\n' '{"reported":true,"conclusion":"success"}'
  exit 0
fi
if [ "$1" = rm ]; then printf '%s\\n' "$3" > ${JSON.stringify(cleanupFile)}; exit 0; fi
exit 0
`, { mode: 0o700 });

let claims = 0;
let claimBody;
let child;
let childExit;
const server = http.createServer(async (req, res) => {
  try {
    assert.equal(req.url, '/-/runner-api/v1/claims');
    assert.equal(req.headers.authorization, `Bearer ${providerToken}`);
    let text = '';
    for await (const chunk of req) text += chunk;
    claimBody = JSON.parse(text);
    assert.match(claimBody.request_id, /^[a-f0-9]{32}$/);
    assert.match(claimBody.attempt_token, /^[a-f0-9]{64}$/);
    claims += 1;
    const assignment = claims === 1 ? {
      version: 1, attempt_id: '17', run_id: '1', job_id: '1',
      repository: 'alice/demo', commit_sha: 'a'.repeat(40),
      lease_until_ms: String(Date.now() + 60000), server_time_ms: String(Date.now()), state: 'leased',
      job: {
        id: 'build', name: 'Build', runs_on: ['self-hosted', 'linux'], timeout_minutes: 1,
        steps: [{ id: 'check', name: 'Check', run: 'true', shell: 'bash', working_directory: '.', env: {}, timeout_minutes: 0 }],
      },
    } : null;
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ version: 1, assignment }));
  } catch (error) {
    res.writeHead(500);
    res.end('{}');
    server.failure = error;
  }
});

function waitForExit(child) {
  return new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
}

(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  child = spawn(binary, [
    'provider', '--server', `http://127.0.0.1:${port}`,
    '--runner-server', `http://127.0.0.1:${port}`,
    '--runner-image', 'registry.example/moonhub-runner:smoke',
    '--docker', fakeDocker, '--docker-host', 'unix:///var/run/docker.sock',
    '--workspace-root', workspace, '--poll-ms', '100', '--allow-http',
    '--token-file', tokenFile,
  ], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.once('close', (code, signal) => { childExit = { code, signal }; });
  const deadline = Date.now() + 15000;
  while (!fs.existsSync(dockerArgsFile)) {
    if (server.failure) throw server.failure;
    if (childExit) throw new Error(`provider exited before launching a container: ${JSON.stringify(childExit)}\nstdout=${stdout}\nstderr=${stderr}`);
    if (Date.now() > deadline) {
      child.kill('SIGKILL');
      await waitForExit(child);
      throw new Error(`provider did not launch a container; claims=${claims}; docker_called=${fs.existsSync(dockerCalledFile)}\nstdout=${stdout}\nstderr=${stderr}`);
    }
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  child.kill('SIGTERM');
  const result = await waitForExit(child);
  assert.equal(server.failure, undefined);
  assert.ok(claimBody);
  assert.equal(fs.readFileSync(cleanupFile, 'utf8').trim(), 'deadbeef');
  assert.equal(fs.readFileSync(attemptTokenFile, 'utf8').length, 64);
  const args = fs.readFileSync(dockerArgsFile, 'utf8');
  assert.match(args, /--read-only/);
  assert.match(args, /--cap-drop ALL/);
  assert.match(args, /no-new-privileges/);
  assert.match(args, /--pids-limit 256/);
  assert.doesNotMatch(args, /--privileged/);
  assert.doesNotMatch(args, new RegExp(providerToken));
  assert.notEqual(result.code, 2, stderr);
  console.log('Provider smoke passed: claim, stdin token handoff, constrained Docker args, and credential separation.');
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
}).finally(() => {
  if (child && !childExit) child.kill('SIGKILL');
  server.closeAllConnections();
  server.close();
  fs.rmSync(root, { recursive: true, force: true });
});
