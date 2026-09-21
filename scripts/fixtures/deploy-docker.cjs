#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const a = process.argv.slice(2);
const line = a.join(' ');
fs.appendFileSync(process.env.TEST_LOG, line + '\n');
const fail = process.env.TEST_FAIL;
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
if (process.env.TEST_BASIC === '1') for (const c of containers) delete c.NetworkSettings.Networks.old_pipeline;
function out(value) { console.log(typeof value === 'string' ? value : JSON.stringify(value)); }
if (/(^| )build /.test(line)) { process.exit(fail === 'build' ? 1 : 0); }
if (line.startsWith('image inspect ')) {
  if (fail === 'image') process.exit(1);
  if (a[2] === '-f') out(process.env.TEST_STORAGE_CHANGE === '1' ? id(9) : a.at(-1).replace('moonhub-recovery:', 'sha256:'));
  else out([{ Id: id(1) }]);
}
else if (line.startsWith('network inspect ')) out((process.env.TEST_BASIC === '1' ? ['default'] : ['default', 'pipeline']).map(key => ({ Name: 'old_' + key, Labels: { 'com.docker.compose.network': key }, IPAM: { Config: [{ Subnet: '172.30.90.0/24' }] } })));
else if (line.startsWith('ps -aq --filter')) { if (process.env.TEST_FRESH !== '1') out(roles.map(r => r + '-id').join('\n')); }
else if (line.startsWith('inspect -f {{.State.Running}}')) out(a.at(-1) === 'pipeline-docker-id' ? 'true' : 'false');
else if (line.startsWith('inspect -f {{.State.Status}}')) out('running');
else if (line.startsWith('inspect ')) out(containers);
else if (line.includes('image inspect -f {{.Id}}')) out('sha256:' + runnerHash);
else if (line.includes('docker.sock ps -aq') && fail === 'active-job') out('active-job');
else if (line.startsWith('cp ')) {
  if (fail === 'backup') process.exit(1);
  if (a[2] === '-') process.stdout.write('archive');
  else if (a[1].endsWith('/ssh-import')) fs.mkdirSync(a[2]);
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
else if (line.startsWith('run ')) { fs.readFileSync(0); if (fail === 'extract') process.exit(1); }
else if (line.includes(' up ') && fail === 'start') process.exit(1);
else if (line.includes('exec -T --user git web sh ') || line.startsWith('exec -i ')) fs.readFileSync(0);
