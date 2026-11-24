import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { ContainerSession, cleanupContainers, argumentWords, imageName } from './containers.mjs';
import { ActionRuntime, execute, metadata } from './runtime.mjs';

async function fixture(t, plan = { job: { image: 'debian:bookworm', env: {}, ports: [], options: [] }, services: {} }) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'moonhub-containers-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  for (const dir of ['work', 'temp', 'home']) await fs.mkdir(path.join(root, dir));
  const config = { workspace: path.join(root, 'work'), temp: path.join(root, 'temp'), job_home: path.join(root, 'home'), container_id: 'a'.repeat(32), container_isolation: true, container_plan: plan, repository: 'alice/demo', sha: 'b'.repeat(40), server: 'https://moonhub.test', node20: process.execPath };
  const calls = [], resources = new Map(); let next = 1, fail;
  const docker = async (args, options = {}) => {
    calls.push({ args, options });
    if (fail?.(args)) throw new Error('injected startup failure');
    const id = () => (next++).toString(16).padStart(64, '0');
    if (args[0] === 'network' && args[1] === 'create') { const value = id(); resources.set(value, 'network'); return value; }
    if (args[0] === 'create') { const value = id(); resources.set(value, 'container'); return value; }
    if (args[0] === 'inspect') return args[2].includes('.State') ? JSON.stringify({ Running: true, Health: { Status: 'healthy' } }) : JSON.stringify({ '5432/tcp': [{ HostIp: '127.0.0.1', HostPort: '34567' }] });
    if (args[0] === 'ps') return [...resources].filter(([, kind]) => kind === 'container').map(([id]) => id).join('\n');
    if (args[1] === 'ls') return [...resources].filter(([, kind]) => kind === args[0]).map(([id]) => id).join('\n');
    if (args[0] === 'rm' || args[1] === 'rm') resources.delete(args.at(-1));
    return '';
  };
  const adapters = { docker, wait: async () => {} };
  const state = {}, session = new ContainerSession(config, state, adapters);
  return { config, state, session, calls, resources, adapters, setFailure: value => { fail = value; } };
}

test('container options and references reject shell and host-control syntax', () => {
  assert.deepEqual(argumentWords('--health-cmd "pg_isready -U postgres" --health-retries 5'), ['--health-cmd', 'pg_isready -U postgres', '--health-retries', '5']);
  assert.deepEqual(argumentWords("sh -c 'echo $INPUT_NAME'"), ['sh', '-c', 'echo $INPUT_NAME']);
  for (const value of ["'unterminated", 'x\\', 'x\0y']) assert.throws(() => argumentWords(value));
  for (const value of ['--privileged', 'https://host/image', 'name; touch x', 'image/../other']) assert.throws(() => imageName(value));
  assert.equal(imageName('registry.example.test:5000/team/image@sha256:' + 'a'.repeat(64)), 'registry.example.test:5000/team/image@sha256:' + 'a'.repeat(64));
});

test('job containers share only selected paths and services use aliases and loopback published ports', { skip: process.platform !== 'linux' }, async t => {
  const f = await fixture(t, { job: { image: 'debian:bookworm', env: {}, options: [], ports: [] }, services: { database: { image: 'postgres:16', env: { REGION: '${{ vars.REGION }}' }, ports: ['5432'], options: ['--health-cmd', 'pg_isready -U postgres'] } } });
  await f.session.ensure({ vars: { REGION: 'east' } });
  const creates = f.calls.filter(call => call.args[0] === 'create');
  assert.equal(creates.length, 2);
  assert.ok(creates[0].args.includes('--network-alias'));
  assert.ok(creates[0].args.includes('database'));
  assert.ok(creates[0].args.includes('127.0.0.1::5432/tcp'));
  assert.equal(creates[0].options.env.REGION, 'east');
  assert.ok(!creates[0].args.includes('east'));
  assert.ok(!creates[0].args.includes('--mount'));
  assert.ok(!creates[1].args.some(value => value.includes('docker.sock') || value.includes('/control/')));
  assert.ok(creates[1].args.includes(`type=bind,src=${f.config.workspace},dst=${f.config.workspace}`));
  assert.equal(f.session.jobContext().services.database.ports['5432'], 34567);
  const command = await f.session.command('/bin/sh', ['-e', '/script'], { PATH: '/custom/bin:/bin', TOKEN: 'do-not-put-in-arguments' }, f.config.workspace, {});
  assert.equal(command.program, '/usr/bin/docker');
  assert.equal(command.env.TOKEN, 'do-not-put-in-arguments');
  assert.equal(command.env.PATH, '/custom/bin:/bin');
  assert.ok(!command.args.includes('do-not-put-in-arguments'));
  assert.ok(command.args.includes('--workdir'));
  await new ContainerSession(f.config, f.state, f.adapters).ensure({});
  assert.equal(f.calls.filter(call => call.args[0] === 'create').length, 2);
  await cleanupContainers(f.config, f.adapters);
  assert.equal(f.resources.size, 0);
});

test('failed startup and unhealthy services clean partially created resources', { skip: process.platform !== 'linux' }, async t => {
  const f = await fixture(t, { job: null, services: { database: { image: 'postgres:16', env: {}, ports: [], options: [] } } });
  f.setFailure(args => args[0] === 'start');
  await assert.rejects(f.session.ensure({}), /startup failure/);
  assert.equal(f.resources.size, 0);
  assert.ok(f.calls.some(call => call.args[0] === 'rm'));
  assert.ok(f.calls.some(call => call.args[0] === 'network' && call.args[1] === 'rm'));
  f.setFailure(undefined);
  const original = f.adapters.docker;
  f.adapters.docker = async (args, options) => args[0] === 'inspect' ? '{"Running":true,"Health":{"Status":"unhealthy"}}' : original(args, options);
  await assert.rejects(new ContainerSession(f.config, {}, f.adapters).ensure({}), /health check/);
  assert.equal(f.resources.size, 0);
});

test('ordinary providers and unsafe container flags never issue Docker commands', { skip: process.platform !== 'linux' }, async t => {
  const f = await fixture(t);
  await assert.rejects(new ContainerSession({ ...f.config, container_isolation: false }, {}, f.adapters).ensure({}), /explicitly isolated/);
  assert.equal(f.calls.length, 0);
  for (const options of [['--privileged', 'true'], ['--volume', '/:/host'], ['--network', 'host'], ['--env-file', '/control/assignment.json']]) {
    const session = new ContainerSession({ ...f.config, container_plan: { job: { image: 'debian:bookworm', env: {}, ports: [], options }, services: {} } }, {}, f.adapters);
    await assert.rejects(session.ensure({}), /Unsupported container option/);
    assert.equal(f.resources.size, 0);
  }
});

test('Docker action command files remain mapped and failed invocations remove their container', { skip: process.platform !== 'linux' }, async t => {
  const f = await fixture(t, { job: null, services: {} });
  const runtime = new ActionRuntime(f.config, f.state, f.adapters);
  runtime.process = async (program, args, env) => {
    assert.equal(program, '/usr/bin/docker');
    assert.ok(args.includes('INPUT_NAME'));
    assert.equal(env.INPUT_NAME, 'value with spaces');
    assert.ok(args.includes(`type=bind,src=${f.config.temp},dst=${f.config.temp}`));
    await fs.writeFile(env.GITHUB_OUTPUT, 'answer=42\n');
    await fs.writeFile(env.GITHUB_ENV, 'NEXT_VALUE=shared\n');
    return 17;
  };
  const result = await runtime.action('docker://busybox:1.37', { name: 'value with spaces', entrypoint: 'sh', args: "-c 'echo fixture'" }, {});
  assert.equal(result.code, 17);
  assert.equal(result.outputs.answer, '42');
  assert.equal(runtime.state.env.NEXT_VALUE, 'shared');
  assert.ok(f.calls.some(call => call.args[0] === 'rm' && call.args.at(-1).includes('-action-')));
  await cleanupContainers(f.config, f.adapters);
  assert.equal(f.resources.size, 0);
});

test('Docker metadata is accepted but needs explicit isolated execution capability', { skip: process.platform !== 'linux' }, async t => {
  const f = await fixture(t);
  const directory = path.join(f.config.workspace, 'action'); await fs.mkdir(directory);
  await fs.writeFile(path.join(directory, 'action.yml'), 'inputs:\n  name: {default: world}\nruns:\n  using: docker\n  image: Dockerfile\n  entrypoint: /entrypoint.sh\n  args: ["${{ inputs.name }}"]\n');
  assert.equal((await metadata(directory)).runs.using, 'docker');
  const result = await execute({ ...f.config, container_plan: null, container_isolation: false, step: { id: 'docker', remote: true, uses: './action', inputs: {} } });
  assert.equal(result.code, 1);
  assert.equal(f.calls.length, 0);
});
