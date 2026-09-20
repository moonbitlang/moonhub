#!/usr/bin/env node
const fs = require('node:fs');
const a = process.argv.slice(2);
const line = a.join(' ');
fs.appendFileSync(process.env.TEST_LOG, line + '\n');
const fail = process.env.TEST_FAIL;
const id = n => 'sha256:' + String(n).repeat(64);
const roles = ['web', 'ssh', 'pipeline-docker', 'pipeline-provider'];
const volume = (Destination, Name) => ({ Type: 'volume', Destination, Name, RW: true });
const bind = Destination => ({ Type: 'bind', Destination, Source: '/old/secret', RW: false });
const containers = roles.map((role, i) => ({
  Id: role + '-id', Image: id(i < 2 ? 1 : i),
  Config: { Labels: { 'com.docker.compose.service': role }, Env: role === 'pipeline-provider' ? ['MOONHUB_RUNNER_IMAGE=old-runner:tag'] : ['LITERAL=$not_an_env'],
    Entrypoint: ['/entrypoint'], Cmd: [role], User: '', WorkingDir: '/app',
    Healthcheck: { Test: ['CMD-SHELL', 'test "$(true)" = ""'], Interval: 1000000000, Timeout: 1000000000, Retries: 3 } },
  HostConfig: { RestartPolicy: { Name: 'unless-stopped' }, Privileged: role === 'pipeline-docker', ReadonlyRootfs: false, PortBindings: {} },
  Mounts: role === 'web' ? [volume('/data', 'old_data'), bind('/run/secrets/root_password'), bind('/run/secrets/ssh-import')] :
    role === 'ssh' ? [volume('/data', 'old_data'), volume('/var/lib/moonhub/ssh', 'old_keys')] :
      role === 'pipeline-provider' ? [bind('/run/secrets/provider_token'), volume('/run/moonhub-docker', 'old_socket'), volume('/var/lib/moonhub/provider', 'old_control')] :
        [volume('/run/moonhub-docker', 'old_socket'), volume('/var/lib/moonhub/provider', 'old_control'), volume('/var/lib/docker', 'old_docker')],
  NetworkSettings: { Networks: { old_default: { IPAMConfig: null }, old_pipeline: { IPAMConfig: { IPv4Address: '172.30.90.' + (10 + i) } } } },
}));
function out(value) { console.log(typeof value === 'string' ? value : JSON.stringify(value)); }
if (/(^| )build /.test(line)) { process.exit(fail === 'build' ? 1 : 0); }
if (line.startsWith('image inspect ')) { if (fail === 'image') process.exit(1); out([{ Id: id(1) }]); }
else if (line.startsWith('network inspect ')) out(['default', 'pipeline'].map(key => ({ Name: 'old_' + key, Labels: { 'com.docker.compose.network': key }, IPAM: { Config: [{ Subnet: '172.30.90.0/24' }] } })));
else if (line.startsWith('ps -aq --filter')) out(roles.map(r => r + '-id').join('\n'));
else if (line.startsWith('inspect -f {{.State.Running}}')) out(a.at(-1) === 'pipeline-docker-id' ? 'true' : 'false');
else if (line.startsWith('inspect -f {{.State.Status}}')) out('running');
else if (line.startsWith('inspect ')) out(containers);
else if (line.includes('image inspect -f {{.Id}}')) out(id(4));
else if (line.includes('docker.sock ps -aq') && fail === 'active-job') out('active-job');
else if (line.startsWith('cp ')) {
  if (fail === 'backup') process.exit(1);
  if (a[2] === '-') process.stdout.write('archive');
  else if (a[1].endsWith('/ssh-import')) fs.mkdirSync(a[2]);
  else fs.writeFileSync(a[2], 'secret');
} else if (line.includes('ps -q ')) out('running-id');
else if (line.startsWith('save ') || line.includes('docker.sock save ')) out('image');
else if (line.includes('exec -T --user git web sh ') || line.startsWith('exec -i ')) fs.readFileSync(0);
