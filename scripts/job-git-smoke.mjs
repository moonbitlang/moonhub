import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
const input = JSON.parse(await new Promise((resolve, reject) => {
  let data = ''; process.stdin.setEncoding('utf8'); process.stdin.on('data', chunk => { data += chunk; }).on('end', () => resolve(data)).on('error', reject);
}));
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'moonhub-job-push-'));
try {
  const git = (args, token = '', expect = true) => {
    const env = { ...process.env, HOME: root, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_TERMINAL_PROMPT: '0' };
    if (token) Object.assign(env, { GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: `http.http://127.0.0.1:${input.port}/.extraheader`, GIT_CONFIG_VALUE_0: 'Authorization: Bearer ' + token });
    const result = spawnSync(process.env.MOONHUB_GIT_CLIENT || 'git', ['-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Job fixture', '-c', 'user.email=fixture@example.test', ...args], { cwd: root, env, encoding: 'utf8', timeout: 30000 });
    assert.equal(result.status === 0, expect, (result.stderr || '').replaceAll(token || 'impossible-token', '***'));
    return result.stdout.trim();
  };
  git(['clone', '--quiet', '--no-local', input.source, 'work']);
  git(['-C', 'work', 'checkout', '--quiet', '-b', 'job-push', input.sha]);
  await fs.writeFile(path.join(root, 'work', 'job-proof'), 'job token push\n');
  git(['-C', 'work', 'add', 'job-proof']); git(['-C', 'work', 'commit', '-qm', 'Job commit']);
  const suffix = input.prefix === '/api/v3' ? 'v3' : 'v1';
  const base = `http://127.0.0.1:${input.port}${input.prefix}/repos/alice/demo/git`;
  if (input.denied) git(['-C', 'work', 'push', base, 'HEAD:refs/heads/expired'], input.token, false);
  else {
    git(['-C', 'work', 'push', base, 'HEAD:refs/heads/job-push-' + suffix], input.token);
    git(['-C', 'work', 'push', base, 'HEAD:refs/tags/job-tag-' + suffix], input.token);
    git(['-C', 'work', 'push', base, 'HEAD:refs/heads/master'], input.token, false);
    git(['-C', 'work', 'push', base, 'HEAD:refs/moonhub/forbidden'], input.token, false);
    git(['-C', 'work', 'push', base.replace('/alice/demo/', '/alice/public/'), 'HEAD:refs/heads/cross-repository'], input.token, false);
  }
  const saved = await fs.readFile(path.join(root, 'work', '.git', 'config'), 'utf8');
  assert.ok(!saved.includes(input.token)); assert.ok(!saved.includes('extraheader'));
  console.log(input.denied ? 'JOB_GIT_DENIED_OK' : 'JOB_GIT_PUSH_AND_POLICY_OK');
} finally { await fs.rm(root, { recursive: true, force: true }); }
