// Exercise the same Wasm entry point used by moonx against an isolated API.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { randomBytes } = require('node:crypto');
const { execFileSync, spawn } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-wasm-'));
const token = 'mh_' + randomBytes(32).toString('hex');
const tokenFile = path.join(temp, 'token');
fs.writeFileSync(tokenFile, token, { mode: 0o600 });
const env = {
  ...process.env,
  HOME: temp,
  XDG_CONFIG_HOME: path.join(temp, 'config'),
  MOONHUB_TOKEN: '',
  MOONHUB_SERVER: '',
  MOONHUB_REPOSITORY: '',
};
const published = process.env.MOONHUB_CLI_PACKAGE;
const executable = published || path.join(root, '_build/wasm/debug/build/cmd/moonhub/moonhub.wasm');
const requests = [];
const server = http.createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  requests.push({
    method: request.method,
    url: request.url,
    authorized: request.headers.authorization === 'Bearer ' + token,
    body: Buffer.concat(chunks).toString('utf8'),
  });
  response.setHeader('Content-Type', 'application/json');
  if (request.headers.authorization !== 'Bearer ' + token) {
    response.writeHead(401).end(JSON.stringify({ error: { message: 'unauthorized' } }));
  } else if (request.url === '/-/api/v1/user') {
    response.end(JSON.stringify({ id: '1', username: 'fixture' }));
  } else if (request.url === '/-/api/v1/repos/fixture/demo/issues' && request.method === 'POST') {
    response.end(JSON.stringify({ number: '1' }));
  } else if (request.url.startsWith('/-/api/v1/repos/fixture/demo/issues?')) {
    response.end(JSON.stringify({ items: [{ number: '1', title: 'Wasm CLI', status: 'open' }] }));
  } else if (request.url === '/-/api/v1/repos/fixture/demo/issues/99') {
    response.writeHead(403).end(JSON.stringify({ error: { message: 'denied\u001b[31m' } }));
  } else if (request.url === '/-/api/v1/repos/fixture/demo/issues/98') {
    response.end('invalid JSON');
  } else if (request.url === '/-/api/v1/repos/fixture/demo/issues/97') {
    response.writeHead(401).end(JSON.stringify({ error: { message: 'token expired' } }));
  } else if (request.url === '/-/api/v1/repos/fixture/demo/issues/96') {
    response.writeHead(409).end(JSON.stringify({ error: { message: 'stale version' } }));
  } else {
    response.writeHead(404).end(JSON.stringify({ error: { message: 'missing fixture' } }));
  }
});

async function cli(args, expected = 0, extraEnv = {}) {
  const child = spawn(published ? 'moonx' : 'moonrun', [executable, '--', ...args], {
    cwd: temp, env: { ...env, ...extraEnv }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '', stderr = '';
  child.stdout.on('data', data => { stdout += data; });
  child.stderr.on('data', data => { stderr += data; });
  const timeout = setTimeout(() => child.kill('SIGKILL'), 30000);
  let code;
  try {
    code = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', resolve);
    });
  } finally {
    clearTimeout(timeout);
  }
  assert.ok(!stdout.includes(token) && !stderr.includes(token), 'CLI exposed a token');
  assert.equal(code, expected, stdout + stderr);
  return { stdout, stderr };
}

async function main() {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port;
  const connection = ['--server', base, '--token-file', tokenFile, '--allow-http', '--json'];
  const help = await cli(['--help']);
  assert.match(help.stdout, /Setup:/);
  assert.match(help.stdout, /auth login --server/);
  assert.match((await cli([])).stdout, /Setup:/);
  assert.match((await cli(['--version'])).stdout, /moonhub 0\.1\.0/);
  assert.match((await cli(['-V'])).stdout, /0\.1\.0/);
  const setup = await cli(['auth', 'setup', '--server', 'https://moonhub.example']);
  assert.ok(setup.stdout.includes('https://moonhub.example/-/settings/tokens'));
  assert.match(setup.stdout, /read.*write.*execute.*merge/);
  const loginHelp = await cli(['auth', 'login', '--help']);
  assert.match(loginHelp.stdout, /Examples and notes:/);
  assert.ok(!loginHelp.stdout.includes('--hunk-id'));
  const mergeHelp = await cli(['help', 'mr', 'merge']);
  assert.match(mergeHelp.stdout, /--version/);
  assert.match(mergeHelp.stdout, /closing_issue_numbers/);
  assert.match((await cli(['mr', 'merge', '1'], 2)).stderr, /--version/);
  await cli(['issue', 'view'], 2);
  assert.match((await cli(['issue', 'comment', '1'], 2)).stderr, /--body-file/);
  for (const command of ['auth', 'mr', 'issue', 'ci', 'inbox', 'attachment', 'webhook', 'secret', 'variable']) {
    assert.ok(help.stdout.includes(command), command + ' missing from help');
  }
  assert.match((await cli(['unknown-command'], 2)).stderr, /unknown|unrecognized/i);
  const missing = await cli(['auth', 'status', '--json'], 2);
  assert.match(missing.stderr, /No MoonHub server configured/);
  assert.match(missing.stderr, /\/-\/settings\/tokens/);
  assert.match(missing.stderr, /auth login --server/);
  const missingToken = await cli(['auth', 'status', '--server', 'https://moonhub.example'], 2);
  assert.match(missingToken.stderr, /No access token/);
  assert.ok(missingToken.stderr.includes('https://moonhub.example/-/settings/tokens'));
  await cli(['auth', 'status', '--server', base, '--token-file', tokenFile], 2);
  assert.equal(requests.length, 0, 'HTTP was contacted without --allow-http');
  assert.equal(JSON.parse((await cli(['auth', 'login', ...connection])).stdout).username, 'fixture');
  const credentials = path.join(env.XDG_CONFIG_HOME, 'moonhub/auth.json');
  assert.equal(JSON.parse(fs.readFileSync(credentials, 'utf8')).server, base);
  if (process.platform !== 'win32') {
    assert.equal(fs.statSync(path.dirname(credentials)).mode & 0o777, 0o700);
    assert.equal(fs.statSync(credentials).mode & 0o777, 0o600);
  }
  assert.equal(JSON.parse((await cli(['auth', 'status', '--allow-http', '--json'])).stdout).username, 'fixture');
  const identity = await cli(['auth', 'status', '--allow-http']);
  assert.match(identity.stdout, /as fixture \(account ID 1\)/);
  assert.match((await cli(['issue', 'list', '--repo', 'invalid', ...connection], 2)).stderr, /--repo must be OWNER\/NAME/);
  const missingFile = await cli(['issue', 'create', '--repo', 'fixture/demo', '--title', 'A title', '--body-file', path.join(temp, 'missing.md'), ...connection], 2);
  assert.match(missingFile.stderr, /Cannot read --body-file/);
  const bodyFile = path.join(temp, 'body.md');
  fs.writeFileSync(bodyFile, 'Wasm reads UTF-8: 月亮\n');
  await cli(['issue', 'create', '--repo', 'fixture/demo', '--title', 'Wasm CLI', '--body-file', bodyFile, ...connection]);
  const created = requests.at(-1);
  assert.equal(created.method, 'POST');
  assert.equal(JSON.parse(created.body).description, fs.readFileSync(bodyFile, 'utf8'));
  execFileSync('git', ['init', '-q', temp]);
  execFileSync('git', ['-C', temp, 'remote', 'add', 'origin', base + '/fixture/demo.git']);
  const list = JSON.parse((await cli(['issue', 'list', ...connection])).stdout);
  assert.equal(list.items[0].number, '1');
  const denied = await cli(['issue', 'view', '99', '--repo', 'fixture/demo', ...connection], 1);
  assert.match(denied.stderr, /HTTP 403: denied/);
  assert.ok(!denied.stderr.includes('\u001b'), 'untrusted terminal escape was printed');
  assert.match(denied.stderr, /repository role/);
  assert.match((await cli(['issue', 'view', '97', '--repo', 'fixture/demo', ...connection], 1)).stderr, /auth setup/);
  assert.match((await cli(['issue', 'view', '96', '--repo', 'fixture/demo', ...connection], 1)).stderr, /latest view\/list --json/);
  const malformed = await cli(['issue', 'view', '98', '--repo', 'fixture/demo', ...connection], 1);
  assert.match(malformed.stderr, /invalid API JSON response/);
  assert.ok(requests.every(request => request.authorized));
  await cli(['auth', 'logout']);
  assert.ok(!fs.existsSync(credentials));
  console.log('Wasm CLI smoke passed: help, auth, private credentials, UTF-8 requests, Git discovery and errors.');
}

main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(temp, { recursive: true, force: true });
});
