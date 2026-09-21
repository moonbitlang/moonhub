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
    env: { ...process.env, ...args, MOONHUB_USE_CN_MIRRORS: '1', ...extra }, encoding: 'utf8', timeout: 5000,
  });
  const sources = path.join(temporary, 'sources.list.d/debian.sources');
  const network = path.join(temporary, 'apt.conf.d/99moonhub-network');
  const stanza = (uri, suites) => `Types: deb\nURIs: ${uri}\nSuites: ${suites}\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n`;
  let result = configure({ MOONHUB_USE_CN_MIRRORS: '' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(sources, 'utf8'), stanza('http://deb.debian.org/debian', 'bookworm bookworm-updates') + '\n' + stanza('http://deb.debian.org/debian-security', 'bookworm-security'), 'default did not use official sources');
  result = configure();
  assert.equal(result.status, 0, result.stderr);
  const expected = stanza(args.DEBIAN_MIRROR, 'bookworm bookworm-updates') + '\n' + stanza(args.DEBIAN_SECURITY_MIRROR, 'bookworm-security');
  assert.equal(fs.readFileSync(sources, 'utf8'), expected);
  assert.equal(fs.readFileSync(network, 'utf8'), 'Acquire::http::Timeout "30";\nAcquire::https::Timeout "30";\nAcquire::Retries "2";\nAPT::Update::Error-Mode "any";\n');
  assert.equal(configure().status, 0);
  assert.equal(fs.readFileSync(sources, 'utf8'), expected, 'repeat configuration appended duplicate sources');
  for (const bad of ['file:///tmp/repository', 'http://', 'http://example.invalid\nTrusted: yes']) {
    for (const key of Object.keys(args)) {
      assert.notEqual(configure({ [key]: bad }).status, 0, `${key} accepted invalid mirror`);
      assert.equal(fs.readFileSync(sources, 'utf8'), expected, 'invalid input changed existing sources');
    }
  }
  for (const bad of ['true', '2', ' 1']) {
    assert.notEqual(configure({ MOONHUB_USE_CN_MIRRORS: bad }).status, 0);
    assert.equal(fs.readFileSync(sources, 'utf8'), expected, 'invalid switch changed existing sources');
  }
  result = configure({ MOONHUB_USE_CN_MIRRORS: '0' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(sources, 'utf8'), stanza('http://deb.debian.org/debian', 'bookworm bookworm-updates') + '\n' + stanza('http://deb.debian.org/debian-security', 'bookworm-security'), 'disabled switch retained domestic mirror overrides');
  assert.equal(configure({ MOONHUB_USE_CN_MIRRORS: '1', DEBIAN_MIRROR: '', DEBIAN_SECURITY_MIRROR: '' }).status, 0);
  assert.equal(fs.readFileSync(sources, 'utf8'), expected, 'empty overrides did not use domestic defaults');
  result = configure({ DEBIAN_MIRROR: 'http://deb.debian.org/debian', DEBIAN_SECURITY_MIRROR: 'https://deb.debian.org/debian-security' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(sources, 'utf8'), stanza('http://deb.debian.org/debian', 'bookworm bookworm-updates') + '\n' + stanza('https://deb.debian.org/debian-security', 'bookworm-security'));
  const dockerfile = fs.readFileSync(path.join(root, 'deploy/base.Dockerfile'), 'utf8');
  assert.ok(dockerfile.includes('ARG MOONHUB_USE_CN_MIRRORS=0'));
  for (const compose of ['compose.yaml', 'deploy/compose.pipeline.yaml']) {
    assert.ok(fs.readFileSync(path.join(root, compose), 'utf8').includes('MOONHUB_BASE_IMAGE: ${MOONHUB_BASE_IMAGE:-moonhub-base:local}'));
  }
  for (const [key, value] of Object.entries(args)) assert.ok(dockerfile.includes(`ARG ${key}=${value}`));
  assert.ok(dockerfile.includes('RUN moon update && moon tree --package'));
  assert.ok(dockerfile.includes('RUN npm ci --no-audit --no-fund'));
  const mainDockerfile = fs.readFileSync(path.join(root, 'Dockerfile'), 'utf8');
  assert.ok(mainDockerfile.includes('ARG MOONHUB_BASE_IMAGE=moonhub-base:local'));
  assert.ok(mainDockerfile.includes('FROM ${MOONHUB_BASE_IMAGE} AS base'));
  const sharedBase = mainDockerfile.split('FROM base AS assets')[0];
  const basePath = sharedBase.match(/^ENV PATH="([^"]+)"$/m)?.[1].split(':');
  assert.ok(basePath, 'shared application base must restore administrative PATH');
  for (const directory of ['/opt/moon/bin', '/usr/local/sbin', '/usr/local/bin', '/usr/sbin', '/usr/bin', '/sbin', '/bin']) {
    assert.ok(basePath.includes(directory), `shared application base PATH is missing ${directory}`);
  }
  assert.ok(sharedBase.includes('RUN --network=none command -v groupadd && command -v useradd && command -v usermod && command -v gosu'));
  assert.ok(mainDockerfile.includes('ENV PATH="/opt/moon/bin:/usr/local/bin:/usr/bin:/bin"\nUSER 10001:10001'), 'job Runner must retain its narrower PATH');
  assert.ok(mainDockerfile.includes('RUN --network=none npm run build'));
  assert.ok(mainDockerfile.includes('RUN --network=none mkdir -p /out'));
  assert.ok(mainDockerfile.includes('moon build --target native --release --deny-warn'));
  assert.ok(!/\bmoon\s+test\b/.test(mainDockerfile), 'image assembly must not execute the test suite');
  assert.ok(dockerfile.includes('RUN sh /tmp/configure-apt.sh && rm /tmp/configure-apt.sh'));
  console.log('APT configuration tests passed: domestic/default source switch, security updates, signatures, fail-fast policy, overrides and all Debian stages.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
