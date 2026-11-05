import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validatePayload } from '../deploy/macos/guest.mjs';
const valid = () => ({
  version: 1,
  server: 'https://moonhub.example',
  token: 'a'.repeat(64),
  assignment: { attempt_id: '1', job: { runs_on: ['self-hosted', 'macos', 'arm64'] } },
});
test('guest envelope validates credentials origin and explicit macOS routing', () => {
  assert.equal(validatePayload(valid()).assignment.attempt_id, '1');
  for (const change of [
    { token: 'secret' },
    { server: 'https://user:password@moonhub.example' },
    { server: 'http://moonhub.example' },
    { server: 'https://moonhub.example/path' },
    { version: 2 },
    { assignment: { attempt_id: '1', job: { runs_on: ['self-hosted', 'linux'] } } },
    { assignment: { attempt_id: '1', job: { runs_on: ['macos', 'windows'] } } },
  ])
    assert.throws(() => validatePayload({ ...valid(), ...change }));
  assert.equal(
    validatePayload({ ...valid(), server: 'http://192.168.64.1:8080', allow_http: true })
      .allow_http,
    true,
  );
});

test(
  'guest reporting does not wait for an escaped descendant holding stdout',
  { skip: process.platform === 'win32' },
  async () => {
    const { spawn } = await import('node:child_process');
    const { collectExecution } = await import('../deploy/macos/guest.mjs');
    const child = spawn(
      process.execPath,
      [
        '-e',
        `
    const {spawn}=require('node:child_process');
    const descendant=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{detached:true,stdio:['ignore',1,2]});
    descendant.unref();console.log(JSON.stringify({reported:true,pid:descendant.pid}));
  `,
      ],
      { stdio: ['pipe', 'pipe', 'pipe'] },
    );
    let pid;
    try {
      const started = Date.now();
      const result = await collectExecution(child, 'a'.repeat(64), 3000);
      const report = JSON.parse(result.output);
      pid = report.pid;
      assert.equal(result.code, 0);
      assert.equal(report.reported, true);
      assert.ok(Date.now() - started < 1500, 'reporting was blocked by a detached pipe holder');
      assert.doesNotThrow(() => process.kill(pid, 0), 'fixture did not keep a descendant alive');
    } finally {
      child.kill('SIGKILL');
      if (pid)
        try {
          process.kill(pid, 'SIGKILL');
        } catch {}
    }
  },
);

test('guest supervisor bounds output and clears timeouts on launch errors', async () => {
  const { spawn } = await import('node:child_process');
  const { collectExecution } = await import('../deploy/macos/guest.mjs');
  const noisy = spawn(
    process.execPath,
    ['-e', "process.stdout.write('x'.repeat(70000));setInterval(()=>{},1000)"],
    { stdio: ['pipe', 'pipe', 'pipe'] },
  );
  await assert.rejects(collectExecution(noisy, 'a'.repeat(64), 3000), /exceeds limits/);
  const missing = spawn('/nonexistent-moonhub-guest-executor', [], {
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  await assert.rejects(collectExecution(missing, 'a'.repeat(64), 3000), { code: 'ENOENT' });
});

test('guest identity allocation rejects collisions and directory lookup failures', async () => {
  const fs = await import('node:fs/promises');
  const { spawnSync } = await import('node:child_process');
  const source = await fs.readFile(
    new URL('../deploy/macos/install-guest.sh', import.meta.url),
    'utf8',
  );
  const guard = source.match(/^assert_identity_owner\(\) \{[\s\S]*?^\}/m)?.[0];
  assert.ok(guard);
  for (const [records, status, expected, success] of [
    ['', 0, '', true],
    ['_moonhub UniqueID = (599)', 0, '_moonhub', true],
    ['_moonhub\t\tUniqueID = (\n    599\n)', 0, '_moonhub', true],
    ['other user UniqueID = (599)', 0, '', false],
    ['unexpected directory output', 0, '', false],
    ['other UniqueID = (599)', 0, '', false],
    ['other PrimaryGroupID = (599)', 0, '_moonhub', false],
    ['_moonhub UniqueID = (599)\nother UniqueID = (599)', 0, '_moonhub', false],
    ['', 1, '', false],
  ]) {
    const script =
      guard +
      '\ndscl() { printf "%s\\n" "$LOOKUP_RECORDS"; return "$LOOKUP_STATUS"; }\nassert_identity_owner /Users UniqueID "$EXPECTED_OWNER"\nprintf installation-would-continue';
    const result = spawnSync('bash', ['-e', '-c', script], {
      encoding: 'utf8',
      env: {
        ...process.env,
        LOOKUP_RECORDS: records,
        LOOKUP_STATUS: String(status),
        EXPECTED_OWNER: expected,
      },
    });
    assert.equal(result.status === 0, success, records);
    assert.equal(result.stdout.includes('installation-would-continue'), success);
  }
});
