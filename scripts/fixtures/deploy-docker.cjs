#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const a = process.argv.slice(2);
if (a[0] === 'pipeline-provider-ensure') {
  const tokenFile = a[a.indexOf('--token-file') + 1];
  if (!/^[a-f0-9]{64}$/.test(fs.readFileSync(tokenFile, 'utf8').trim())) process.exit(1);
  fs.appendFileSync(process.env.TEST_LOG, 'provider-ensure-argv ' + JSON.stringify(a) + '\n');
  process.exit(0);
}
const line = a.join(' ');
fs.appendFileSync(process.env.TEST_LOG, line + '\n');
if (a[0] === 'compose' && a.includes('build')) {
  fs.appendFileSync(process.env.TEST_LOG, 'compose-base ' + process.env.MOONHUB_BASE_IMAGE + '\n');
}
const fail = process.env.TEST_FAIL;
if (fail === 'export' && (line.startsWith('save ') || line.includes('docker.sock save '))) {
  process.stdout.write('incomplete export');
  process.exit(1);
}
const id = n => 'sha256:' + String(n).repeat(64);
const config = '{}';
const runnerHash = createHash('sha256').update(config).digest('hex');
const roles = process.env.TEST_BASIC === '1' ? ['web', 'ssh'] : ['web', 'ssh', 'pipeline-docker', 'pipeline-provider'];
const volume = (Destination, Name) => ({ Type: 'volume', Destination, Name, RW: true });
const bind = Destination => ({ Type: 'bind', Destination, Source: '/old/secret', RW: false });
const containers = roles.map((role, i) => ({
  Id: role + '-id', Image: id(i < 2 ? 1 : i),
  Config: { Labels: { 'com.docker.compose.service': role }, Env: role === 'pipeline-provider' ? ['MOONHUB_RUNNER_IMAGE=old-runner:tag'] : ['LITERAL=$not_an_env'],
    Entrypoint: ['/entrypoint'], Cmd: [role], User: '', WorkingDir: '/app',
    Healthcheck: { Test: ['CMD-SHELL', 'test "$(true)" = ""'], Interval: 1000000000, Timeout: 1000000000, Retries: 3 } },
  HostConfig: { RestartPolicy: { Name: 'unless-stopped' }, Privileged: role === 'pipeline-docker', ReadonlyRootfs: false,
    PortBindings: role === 'web' ? { '8080/tcp': [{ HostPort: '8080', HostIp: '127.0.0.1' }] } :
      role === 'ssh' ? { '2222/tcp': [{ HostPort: '2222', HostIp: '127.0.0.1' }] } : {} },
  Mounts: role === 'web' ? [volume('/data', 'old_data'), bind('/run/secrets/root_password'), bind('/run/secrets/ssh-import')] :
    role === 'ssh' ? [volume('/data', 'old_data'), volume('/var/lib/moonhub/ssh', 'old_keys')] :
      role === 'pipeline-provider' ? [bind('/run/secrets/provider_token'), volume('/run/moonhub-docker', 'old_socket'), volume('/var/lib/moonhub/provider', 'old_control')] :
        [volume('/run/moonhub-docker', 'old_socket'), volume('/var/lib/moonhub/provider', 'old_control'), volume('/var/lib/docker', 'old_docker')],
  NetworkSettings: { Networks: { old_default: { IPAMConfig: null }, old_pipeline: { IPAMConfig: { IPv4Address: '172.30.90.' + (10 + i) } } } },
}));
if (process.env.TEST_BAD_MOUNT === '1') containers[0].Mounts.push(bind('/unsupported-secret'));
if (process.env.TEST_OIDC === '1') {
  containers[0].Mounts.push(bind('/run/secrets/workflow_oidc'));
  containers[0].Config.Env.push('MOONHUB_OIDC_CONFIG=/run/secrets/workflow_oidc');
}
if (process.env.TEST_STORAGE_CONFIG === '1') {
  containers[0].Mounts.push(bind('/run/secrets/blob_storage'));
  containers[0].Config.Env.push('MOONHUB_STORAGE_CONFIG=/run/secrets/blob_storage');
}
if (process.env.TEST_STORAGE_AWS === '1') {
  containers[0].Mounts.push(bind('/run/secrets/storage_aws'));
  containers[0].Config.Env.push('AWS_CONFIG_FILE=/run/secrets/storage_aws/config');
}
if (process.env.TEST_BASIC === '1') for (const c of containers) delete c.NetworkSettings.Networks.old_pipeline;
if (process.env.TEST_RESOURCE_LIMITS === '1') for (const c of containers) Object.assign(c.HostConfig, {
  CgroupParent: 'moonhub.slice', CgroupnsMode: 'private', NanoCpus: 500000000,
  Memory: 536870912, MemorySwap: 536870912, PidsLimit: 128,
  LogConfig: { Type: 'json-file', Config: { 'max-size': '10m', 'max-file': '3' } },
});
function out(value) { console.log(typeof value === 'string' ? value : JSON.stringify(value)); }
if (/(^| )build /.test(line)) {
  if (fail === 'build' || (fail === 'base-build' && line.includes('base.Dockerfile'))) process.exit(1);
  if (line.includes('base.Dockerfile')) fs.writeFileSync(process.env.TEST_LOG + '.base', 'built');
  process.exit(0);
}
if (line.startsWith('image inspect ')) {
  if (fail === 'image') process.exit(1);
  if (process.env.TEST_BASE_MISSING === '1' && line.includes('moonhub-base:') && !fs.existsSync(process.env.TEST_LOG + '.base')) process.exit(1);
  if (a[2] === '-f') out(process.env.TEST_STORAGE_CHANGE === '1' ? id(9) : a.at(-1).replace('moonhub-recovery:', 'sha256:'));
  else out([{ Id: id(1) }]);
}
else if (line.startsWith('info --format')) out('linux/amd64');
else if (line.startsWith('network inspect ')) out((process.env.TEST_BASIC === '1' ? ['default'] : ['default', 'pipeline']).map(key => ({ Name: 'old_' + key, Labels: { 'com.docker.compose.network': key }, IPAM: { Config: [{ Subnet: '172.30.90.0/24' }] } })));
else if (line.startsWith('ps -aq --filter')) { if (process.env.TEST_FRESH !== '1') out(roles.map(r => r + '-id').join('\n')); }
else if (line.startsWith('ps -q --filter')) {
  if (process.env.TEST_FRESH !== '1' && process.env.TEST_BASIC !== '1') {
    const service = a.at(-1).split('=').at(-1); out(service + '-id');
  }
}
else if (line.startsWith('inspect -f {{.State.Paused}}')) out('false');
else if (line.startsWith('inspect -f {{.State.Running}}')) out(a.at(-1) === 'pipeline-docker-id' ? 'true' : 'false');
else if (line.startsWith('inspect -f {{.State.Status}}')) out('running');
else if (line.startsWith('inspect ')) out(containers);
else if (line.includes('image inspect -f {{.Id}}')) out('sha256:' + runnerHash);
else if (line.includes('docker.sock ps -aq') && (fail === 'active-job' || process.env.TEST_ACTIVE === '1') && !fs.existsSync(process.env.TEST_LOG + '.job-stopped')) out('active-job');
else if (line.includes('docker.sock stop -t')) fs.writeFileSync(process.env.TEST_LOG + '.job-stopped', 'stopped');
else if (line.includes('exec -i --user git') && line.includes('node --no-warnings')) {
  fs.readFileSync(0);
  out(fail === 'active-job' || process.env.TEST_ACTIVE === '1' || process.env.TEST_LEASED === '1' ? '1' : '0');
}
else if (line.startsWith('cp ')) {
  if (fail === 'backup') process.exit(1);
  if (a[2] === '-') process.stdout.write('archive');
  else if (a[1].endsWith('/ssh-import') || a[1].endsWith('/storage_aws')) fs.mkdirSync(a[2]);
  else fs.writeFileSync(a[2], 'secret');
} else if (line.includes('ps -q ')) out('running-id');
else if (line.includes('docker.sock save ')) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'runner-tar-'));
  try {
    fs.writeFileSync(path.join(temp, runnerHash + '.json'), config);
    fs.writeFileSync(path.join(temp, 'manifest.json'), JSON.stringify([{ Config: runnerHash + '.json' }]));
    process.stdout.write(execFileSync('tar', ['-cf', '-', 'manifest.json', runnerHash + '.json'], { cwd: temp }));
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
}
else if (line.startsWith('save ')) out('image');
else if (line.startsWith('run ')) { fs.readFileSync(0); if (fail === 'extract' || (line.includes('oidc-check') && fail === 'oidc-config') || (line.includes('storage-check') && fail === 'storage-config')) process.exit(1); }
else if (line.includes('exec -T --user git web node')) { fs.readFileSync(0); if (fail === 'oidc-health') process.exit(1); }
else if (line.includes(' up ') && fail === 'start') process.exit(1);
else if (line.includes('exec -T --user git web sh ')) {
  execFileSync('sh', a.slice(a.indexOf('sh') + 1), { input: fs.readFileSync(0) });
}
else if (line.startsWith('exec -i ')) fs.readFileSync(0);
