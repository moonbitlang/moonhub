const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-install-test-'));
try {
  const bin = path.join(temporary, 'bin');
  const downloads = path.join(temporary, 'downloads');
  fs.mkdirSync(bin);
  fs.mkdirSync(downloads);
  const log = path.join(temporary, 'curl.json');
  const installed = path.join(temporary, 'installed-version');
  const moonHome = path.join(temporary, 'moon');
  fs.writeFileSync(path.join(bin, 'curl'), `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.writeFileSync(process.env.TEST_CURL_LOG, JSON.stringify(args));
fs.writeFileSync(args[args.indexOf('--output') + 1], 'printf "%s\\\\n" "$1" > "$TEST_INSTALL_LOG"\\nexit "\${TEST_INSTALL_FAIL:-0}"\\n');
process.exit(Number(process.env.TEST_DOWNLOAD_FAIL || 0));
`, { mode: 0o755 });
  const version = '0.10.14+7d59c7ec9';
  const run = (extra = {}) => {
    for (const file of [log, installed, path.join(moonHome, 'config.json')]) fs.rmSync(file, { force: true });
    const result = spawnSync('sh', [path.join(root, 'deploy/install-moonbit.sh'), version], {
      env: { ...process.env, PATH: bin + ':' + process.env.PATH, TMPDIR: downloads, MOON_HOME: moonHome,
        MOONHUB_USE_CN_MIRRORS: '', TEST_CURL_LOG: log, TEST_INSTALL_LOG: installed,
        TEST_INSTALL_FAIL: '', TEST_DOWNLOAD_FAIL: '', ...extra }, encoding: 'utf8', timeout: 5000,
    });
    assert.deepEqual(fs.readdirSync(downloads), [], 'installer temporary file leaked');
    return result;
  };
  for (const [toggle, host] of [['', 'com'], ['1', 'cn'], ['0', 'com']]) {
    const result = run({ MOONHUB_USE_CN_MIRRORS: toggle });
    assert.equal(result.status, 0, result.stderr);
    const args = JSON.parse(fs.readFileSync(log));
    assert.ok(args.includes(`https://cli.moonbitlang.${host}/install/unix.sh`));
    assert.ok(args.includes('--fail'));
    assert.ok(args.includes('--connect-timeout'));
    assert.ok(!args.includes('--insecure'));
    assert.equal(fs.readFileSync(installed, 'utf8'), version + '\n');
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(moonHome, 'config.json'))), host === 'cn' ? {
      download: 'https://mirrors.ustc.edu.cn/mooncakes', index: 'https://mirrors.ustc.edu.cn/mooncakes.git', api: 'https://mooncakes.io',
    } : {});
  }
  for (const bad of ['true', '2', ' 1']) {
    assert.notEqual(run({ MOONHUB_USE_CN_MIRRORS: bad }).status, 0);
    assert.ok(!fs.existsSync(log), 'invalid switch reached the network');
  }
  assert.equal(run({ TEST_DOWNLOAD_FAIL: '22' }).status, 22);
  assert.ok(!fs.existsSync(installed), 'failed download executed a partial installer');
  assert.equal(run({ TEST_INSTALL_FAIL: '17' }).status, 17);
  assert.ok(!fs.existsSync(path.join(moonHome, 'config.json')), 'failed installation rewrote registry configuration');
  const dockerfile = fs.readFileSync(path.join(root, 'deploy/base.Dockerfile'), 'utf8');
  assert.ok(dockerfile.includes('COPY deploy/install-moonbit.sh /tmp/moonhub-install-moonbit.sh'));
  assert.ok(dockerfile.includes('RUN sh /tmp/moonhub-install-moonbit.sh "$MOONBIT_VERSION"'));
  console.log('MoonBit installation tests passed: regional switch, pinned version, validation, download/install failures and temporary file cleanup.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
