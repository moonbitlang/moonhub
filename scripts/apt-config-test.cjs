const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'moonhub-apt-test-'));
try {
  const args = { DEBIAN_MIRROR: 'http://mirrors.ustc.edu.cn/debian', DEBIAN_SECURITY_MIRROR: 'http://mirrors.ustc.edu.cn/debian-security' };
  const configure = (extra = {}) => spawnSync('sh', [path.join(root, 'deploy/configure-apt.sh'), temporary], {
    env: { ...process.env, ...args, ...extra }, encoding: 'utf8', timeout: 5000,
  });
  const sources = path.join(temporary, 'sources.list.d/debian.sources');
  const network = path.join(temporary, 'apt.conf.d/99moonhub-network');
  const stanza = (uri, suites) => `Types: deb\nURIs: ${uri}\nSuites: ${suites}\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n`;
  let result = configure();
  assert.equal(result.status, 0, result.stderr);
  const expected = stanza(args.DEBIAN_MIRROR, 'bookworm bookworm-updates') + '\n' + stanza(args.DEBIAN_SECURITY_MIRROR, 'bookworm-security');
  assert.equal(fs.readFileSync(sources, 'utf8'), expected);
  assert.equal(fs.readFileSync(network, 'utf8'), 'Acquire::http::Timeout "30";\nAcquire::https::Timeout "30";\nAcquire::Retries "2";\nAPT::Update::Error-Mode "any";\n');
  assert.equal(configure().status, 0);
  assert.equal(fs.readFileSync(sources, 'utf8'), expected, 'repeat configuration appended duplicate sources');
  for (const bad of ['', 'file:///tmp/repository', 'http://', 'http://example.invalid\nTrusted: yes']) {
    for (const key of Object.keys(args)) {
      assert.notEqual(configure({ [key]: bad }).status, 0, `${key} accepted invalid mirror`);
      assert.equal(fs.readFileSync(sources, 'utf8'), expected, 'invalid input changed existing sources');
    }
  }
  result = configure({ DEBIAN_MIRROR: 'http://deb.debian.org/debian', DEBIAN_SECURITY_MIRROR: 'https://deb.debian.org/debian-security' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(sources, 'utf8'), stanza('http://deb.debian.org/debian', 'bookworm bookworm-updates') + '\n' + stanza('https://deb.debian.org/debian-security', 'bookworm-security'));
  const dockerfile = fs.readFileSync(path.join(root, 'Dockerfile'), 'utf8');
  for (const [key, value] of Object.entries(args)) {
    assert.ok(dockerfile.includes(`ARG ${key}=${value}`));
    for (const compose of ['compose.yaml', 'deploy/compose.pipeline.yaml']) {
      assert.ok(fs.readFileSync(path.join(root, compose), 'utf8').includes(`${key}: \${${key}:-${value}}`));
    }
  }
  for (const stage of ['toolchain', 'runner', 'provider', 'runtime']) assert.ok(dockerfile.includes(`FROM debian-base AS ${stage}`));
  assert.ok(dockerfile.includes('RUN sh /tmp/configure-apt.sh && rm /tmp/configure-apt.sh'));
  console.log('APT configuration tests passed: domestic defaults, security updates, signatures, fail-fast policy, overrides and all Debian stages.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
