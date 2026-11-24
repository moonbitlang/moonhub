import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { interpolateAsync as interpolate } from './expression.mjs';
import { validEnvName } from './commands.mjs';

const docker = '/usr/bin/docker';
const label = 'io.moonhub.workflow';
const imagePattern = /^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,511}$/;
const flags = new Set(['--cpus', '--memory', '--memory-swap', '--shm-size', '--user', '--health-cmd', '--health-interval', '--health-timeout', '--health-retries', '--health-start-period']);
export function imageName(value) {
  if (typeof value !== 'string' || !imagePattern.test(value) || value.includes('..') || value.includes('://')) throw new Error('Invalid container image');
  return value;
}
export function argumentWords(value) {
  if (typeof value !== 'string' || value.length > 4096 || value.includes('\0')) throw new Error('Invalid container arguments');
  const result = []; let word = '', quote = '', escaped = false, started = false;
  for (const char of value) {
    if (escaped) { word += char; escaped = false; started = true; continue; }
    if (char === '\\' && quote !== "'") { escaped = true; started = true; continue; }
    if (quote) { if (char === quote) quote = ''; else word += char; continue; }
    if (char === '"' || char === "'") { quote = char; started = true; continue; }
    if (/[ \t\r\n]/.test(char)) { if (started) { result.push(word); word = ''; started = false; } }
    else { word += char; started = true; }
  }
  if (quote || escaped) throw new Error('Unterminated container arguments');
  if (started) result.push(word);
  if (result.length > 128) throw new Error('Too many container arguments');
  return result;
}
function options(values = [], job = false) {
  if (!Array.isArray(values) || values.length > 32 || values.length % 2) throw new Error('Container options require flag/value pairs');
  for (let i = 0; i < values.length; i += 2) {
    if (!flags.has(values[i]) || typeof values[i + 1] !== 'string' || !values[i + 1] || values[i + 1].startsWith('-') || /[\0\r\n]/.test(values[i + 1])) throw new Error('Unsupported container option');
    if (job && values[i] === '--user') throw new Error('--user is supported only on service containers');
  }
  return values;
}
function ports(values = []) {
  if (!Array.isArray(values) || values.length > 16) throw new Error('Too many container ports');
  return values.map(value => {
    if (typeof value !== 'string' || !/^\d{1,5}(:\d{1,5})?(\/(tcp|udp))?$/.test(value)) throw new Error('Invalid container port');
    const [numbers, protocol = 'tcp'] = value.split('/'), parts = numbers.split(':').map(Number);
    if (parts.some(n => n < 1 || n > 65535)) throw new Error('Invalid container port');
    return `127.0.0.1:${parts.length === 2 ? parts[0] : ''}:${parts.at(-1)}/${protocol}`;
  });
}
function ownedId(id) {
  if (!/^[a-f0-9]{32}$/.test(id || '')) throw new Error('Container execution identity is unavailable');
  return id;
}
async function isolated(config, adapters) {
  if (process.platform !== 'linux' || config.container_isolation !== true) throw new Error('Containers require an explicitly isolated Linux CI provider');
  if (!adapters.docker && (await fs.readFile('/run/moonhub-ci/profile', 'utf8')).trim() !== 'linux-ci-v1') throw new Error('Job-local Docker isolation is unavailable');
}
function clientEnvironment(values = {}) {
  // Never accept workflow-selected Docker hosts, client configuration, TLS or
  // contexts. Credentials enter exec via inherited values, never CLI arguments.
  const result = Object.fromEntries(Object.entries(values).filter(([name]) => !name.startsWith('DOCKER_')));
  return { ...result, PATH: values.PATH || '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', DOCKER_HOST: 'unix:///var/run/docker.sock', DOCKER_CONFIG: '/run/moonhub-ci/client', DOCKER_CONTEXT: '' };
}
export async function control(args, { timeout = 120000, env = {} } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(docker, args, { env: clientEnvironment(env), stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', size = 0, exceeded = false;
    const timer = setTimeout(() => child.kill('SIGKILL'), timeout);
    child.stdout.on('data', chunk => { size += chunk.length; if (size > 1048576) { exceeded = true; child.kill('SIGKILL'); } else stdout += chunk; });
    child.stderr.on('data', chunk => { size += chunk.length; if (size > 1048576) { exceeded = true; child.kill('SIGKILL'); } });
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('close', code => {
      clearTimeout(timer);
      if (code || code === null || exceeded) reject(new Error(`Container ${args[0]} failed or exceeded its deadline`));
      else resolve(stdout.trim());
    });
  });
}
export async function cleanupContainers(config, adapters = {}) {
  await isolated(config, adapters);
  const id = ownedId(config.container_id), call = adapters.docker || control;
  let failed = false;
  for (const [list, remove] of [
    [['ps', '-aq', '--filter', `label=${label}=${id}`], ['rm', '-f', '-v']],
    [['network', 'ls', '-q', '--filter', `label=${label}=${id}`], ['network', 'rm']],
    [['image', 'ls', '-q', '--filter', `label=${label}=${id}`], ['image', 'rm', '-f']],
  ]) {
    try {
      const ids = (await call(list, { timeout: 10000 })).split(/\s+/).filter(Boolean);
      if (ids.some(value => !/^[a-f0-9]{12,64}$/.test(value)) || ids.length > 512) throw new Error('Invalid Docker resource identity');
      for (const resource of new Set(ids)) await call([...remove, resource], { timeout: 10000 });
    } catch { failed = true; }
  }
  if (failed) throw new Error('Container cleanup could not be verified');
}

export class ContainerSession {
  constructor(config, state, adapters = {}) {
    this.config = config; this.state = state; this.adapters = adapters;
    this.call = adapters.docker || control;
    this.id = ownedId(config.container_id);
    this.prefix = `moonhub-${this.id}`;
    this.plan = config.container_plan || { job: null, services: {} };
    this.resources = state.containers || { id: this.id, services: {}, initialized: false };
    if (this.resources.id !== this.id) throw new Error('Container state belongs to another execution');
    state.containers = this.resources;
  }
  async mounts() {
    const specs = [
      [this.config.workspace, false], [this.config.temp, false], [this.config.job_home, false],
      [this.config.source_git, true], [process.execPath, true],
      ...(this.config.node20 ? [[this.config.node20, true]] : []),
    ];
    const result = [], seen = new Set();
    for (const [requested, readOnly] of specs) {
      if (!requested) continue;
      const resolved = await fs.realpath(requested);
      if (!path.isAbsolute(resolved) || !path.isAbsolute(requested) || resolved === '/' || /[,\r\n\0]/.test(resolved + requested)) throw new Error('Invalid container mount');
      if (seen.has(requested)) continue;
      seen.add(requested);
      result.push('--mount', `type=bind,src=${resolved},dst=${requested}${readOnly ? ',readonly' : ''}`);
    }
    return result;
  }
  async spec(value, context, job = false) {
    if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !['image', 'env', 'ports', 'options'].includes(key))) throw new Error('Invalid container definition');
    const image = imageName(await interpolate(value.image, context)), env = {};
    if (value.env && (typeof value.env !== 'object' || Array.isArray(value.env))) throw new Error('Invalid container environment');
    const entries = Object.entries(value.env || {});
    if (entries.length > 100) throw new Error('Too many container environment values');
    for (const [name, template] of entries) {
      if (!validEnvName(name) || name.startsWith('DOCKER_') || typeof template !== 'string') throw new Error('Invalid container environment value');
      env[name] = await interpolate(template, context);
      if (env[name].includes('\0') || Buffer.byteLength(env[name]) > 65536) throw new Error('Container environment value exceeds limits');
    }
    return { image, env, ports: ports(value.ports), options: options(value.options, job) };
  }
  async create(name, spec, { job = false, alias = '' } = {}) {
    await this.call(['pull', spec.image]);
    const args = ['create', '--name', name, '--label', `${label}=${this.id}`, '--network', this.resources.network, '--pids-limit', '256'];
    if (alias) args.push('--network-alias', alias);
    for (const port of spec.ports) args.push('--publish', port);
    if (job) args.push('--user', '0:0', '--workdir', this.config.workspace, ...await this.mounts(), '--entrypoint', '/bin/sh');
    args.push(...spec.options);
    for (const name of Object.keys(spec.env)) args.push('--env', name);
    args.push(spec.image);
    if (job) args.push('-c', 'while :; do sleep 3600; done');
    const id = await this.call(args, { env: spec.env });
    if (!/^[a-f0-9]{12,64}$/.test(id)) throw new Error('Invalid created container identity');
    await this.call(['start', id]);
    return id;
  }
  async healthy(id) {
    const deadline = Date.now() + 120000;
    for (let attempt = 0; attempt < 240 && Date.now() < deadline; attempt++) {
      const info = JSON.parse(await this.call(['inspect', '--format', '{{json .State}}', id], { timeout: 10000 }));
      if (!info.Running || info.Health?.Status === 'unhealthy') throw new Error('Service container failed its health check');
      if (!info.Health || info.Health.Status === 'healthy') return;
      await (this.adapters.wait || (ms => new Promise(resolve => setTimeout(resolve, ms))))(500);
    }
    throw new Error('Service container health deadline expired');
  }
  async ensure(context) {
    await isolated(this.config, this.adapters);
    if (this.resources.initialized) return;
    if (!this.plan || typeof this.plan !== 'object' || Array.isArray(this.plan) || Object.keys(this.plan).some(key => !['job', 'services'].includes(key)) || !this.plan.services || typeof this.plan.services !== 'object' || Array.isArray(this.plan.services) || Buffer.byteLength(JSON.stringify(this.plan)) > 65536) throw new Error('Invalid container plan');
    const services = Object.entries(this.plan.services || {});
    if (services.length > 8 || services.some(([name]) => !/^[A-Za-z_][A-Za-z0-9_-]{0,62}$/.test(name) || ['localhost', 'job', 'host'].includes(name.toLowerCase()))) throw new Error('Invalid service alias');
    const { github = {}, inputs, vars, needs, matrix, strategy } = context;
    const { token, ...publicGithub } = github;
    const publicContext = { github: publicGithub, inputs, vars, needs, matrix, strategy };
    try {
      const network = await this.call(['network', 'create', '--label', `${label}=${this.id}`, `${this.prefix}-network`]);
      if (!/^[a-f0-9]{12,64}$/.test(network)) throw new Error('Invalid container network identity');
      this.resources.network = network;
      for (const [name, value] of services) {
        const id = await this.create(`${this.prefix}-${name}`, await this.spec(value, publicContext), { alias: name });
        this.resources.services[name] = { id, network, ports: {} };
        await this.healthy(id);
        const published = JSON.parse(await this.call(['inspect', '--format', '{{json .NetworkSettings.Ports}}', id]));
        for (const [port, bindings] of Object.entries(published || {})) {
          const binding = bindings?.find(value => value.HostIp === '127.0.0.1');
          if (binding) this.resources.services[name].ports[port.split('/')[0]] = Number(binding.HostPort);
        }
      }
      if (this.plan.job) this.resources.job = await this.create(`${this.prefix}-job`, await this.spec(this.plan.job, publicContext, true), { job: true });
      this.resources.initialized = true;
    } catch (error) {
      try { await cleanupContainers(this.config, this.adapters); } catch {}
      throw error;
    }
  }
  jobContext() { return { container: this.resources.job ? { id: this.resources.job, network: this.resources.network } : {}, services: this.resources.services }; }
  async command(program, args, env, cwd, context) {
    await this.ensure(context);
    if (!this.resources.job) return { program, args, env, cwd };
    const command = ['exec', '--workdir', cwd];
    for (const name of Object.keys(env)) { if (name.startsWith('DOCKER_')) throw new Error('Docker client environment is reserved'); command.push('--env', name); }
    command.push(this.resources.job, program, ...args);
    return { program: docker, args: command, env: clientEnvironment(env), cwd };
  }
  async action(image, args, entrypoint, env, cwd, context, execute) {
    await this.ensure(context);
    imageName(image);
    const name = `${this.prefix}-action-${randomUUID()}`;
    const command = ['run', '--rm', '--name', name, '--label', `${label}=${this.id}`, '--network', this.resources.network, '--pids-limit', '256', '--user', '0:0', '--workdir', cwd, ...await this.mounts()];
    for (const key of Object.keys(env)) { if (key.startsWith('DOCKER_')) throw new Error('Docker client environment is reserved'); command.push('--env', key); }
    if (entrypoint) {
      if (typeof entrypoint !== 'string' || /[\0\r\n]/.test(entrypoint) || entrypoint.length > 512) throw new Error('Invalid Docker action entrypoint');
      command.push('--entrypoint', entrypoint);
    }
    if (!Array.isArray(args) || args.length > 128 || Buffer.byteLength(JSON.stringify(args)) > 65536 || args.some(value => typeof value !== 'string' || value.includes('\0') || value.length > 65536)) throw new Error('Invalid Docker action arguments');
    command.push(image, ...args);
    try { return await execute(docker, command, clientEnvironment(env), cwd); }
    finally { await this.call(['rm', '-f', '-v', name], { timeout: 10000 }).catch(() => {}); }
  }
  async build(directory, dockerfile) {
    await isolated(this.config, this.adapters);
    const tag = `${this.prefix}-image-${randomUUID()}`;
    await this.call(['build', '--label', `${label}=${this.id}`, '--tag', tag, '--file', dockerfile, directory]);
    return tag;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] !== 'cleanup') throw new Error('Unknown container operation');
  cleanupContainers({ container_isolation: true, container_id: process.argv[3] }).catch(() => { process.stderr.write('runner: container cleanup could not be verified\n'); process.exitCode = 1; });
}
