const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

test('SSH entrypoint validates deployment limits before writing its private runtime configuration', () => {
  const root = path.resolve(__dirname, '..');
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-ssh-entrypoint-'));
  try {
    // Redirect container-only paths into this fixture. Execute the actual shell
    // validation and config generation; only the final sshd invocation is a stub.
    const paths = new Map([
      ['/run/sshd', path.join(temp, 'run/sshd')],
      ['/run/moonhub-sshd', path.join(temp, 'runtime')],
      ['/var/lib/moonhub/ssh', path.join(temp, 'keys')],
      ['/etc/ssh/moonhub_sshd_config', path.join(temp, 'static-config')],
      ['/usr/sbin/sshd', path.join(temp, 'sshd')],
    ]);
    let source = fs.readFileSync(path.join(root, 'deploy/entrypoint.sh'), 'utf8');
    for (const [original, replacement] of paths) source = source.replaceAll(original, replacement);
    const script = path.join(temp, 'entrypoint');
    fs.writeFileSync(script, source);
    fs.mkdirSync(path.join(temp, 'keys'));
    fs.writeFileSync(path.join(temp, 'keys/ssh_host_ed25519_key'), 'fixture');
    const staticConfig = fs.readFileSync(path.join(root, 'deploy/sshd_config'), 'utf8');
    fs.writeFileSync(path.join(temp, 'static-config'), staticConfig);
    const config = path.join(temp, 'runtime/sshd_config');
    const env = { ...process.env };
    const idle = 'MOONHUB_SSH_READ_IDLE_TIMEOUT_SECONDS', maximum = 'MOONHUB_SSH_READ_MAX_SECONDS';
    delete env[idle]; delete env[maximum];
    // The stub accepts both `-t -f path` and `-D -e -f path` invocations.
    fs.writeFileSync(path.join(temp, 'sshd'), '#!/bin/sh\nfor arg do last=$arg; done\ntest -f "$last"\n', { mode: 0o700 });
    for (const [overrides, expectedIdle, expectedMax] of [
      [{}, '120', '3600'],
      [{ [idle]: '1', [maximum]: '2147483' }, '1', '2147483'],
      [{ [idle]: '00000001', [maximum]: '0003600' }, '00000001', '0003600'],
    ]) {
      const result = spawnSync('sh', [script, 'ssh'], { env: { ...env, ...overrides }, encoding: 'utf8', timeout: 10000 });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, '');
      const text = fs.readFileSync(config, 'utf8');
      // OpenSSH ignores subsequent SetEnv directives. Keep fixed deployment
      // settings and the two runtime limits together on the first and only one.
      const directives = text.split('\n').filter(line => line.startsWith('SetEnv '));
      assert.deepEqual(directives, [
        `SetEnv DB_PATH=/data/moonhub.db MOONHUB_REPO_ROOT=/data/repos MOONHUB_GIT=/usr/bin/git ${idle}=${expectedIdle} ${maximum}=${expectedMax}`,
      ]);
      assert.equal(text.replace(directives[0], staticConfig.split('\n').find(line => line.startsWith('SetEnv '))), staticConfig);
      assert.deepEqual(text.split('\n').filter(line => line.startsWith('AcceptEnv ')), ['AcceptEnv GIT_PROTOCOL']);
      assert.equal(fs.statSync(config).mode & 0o777, 0o600);
      assert.equal(fs.statSync(path.dirname(config)).mode & 0o777, 0o700);
    }
    for (const name of [idle, maximum]) {
      for (const value of ['', '0', '00000', '-1', '+1', '1.5', ' 1', '1\nSetEnv BAD=1', '2147484', '2147483648', '999999999999999999999999999999999999']) {
        fs.rmSync(config, { force: true });
        const result = spawnSync('sh', [script, 'ssh'], { env: { ...env, [name]: value }, encoding: 'utf8', timeout: 10000 });
        assert.equal(result.status, 1, `accepted ${name}=${JSON.stringify(value)}`);
        assert.match(result.stderr, /SSH read timeouts must be integers between 1 and 2147483/);
        assert.equal(result.stdout, '');
        assert.equal(fs.existsSync(config), false, 'invalid input reached runtime config generation');
      }
    }
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
});
