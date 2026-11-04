import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { parseDocument } from 'yaml';
import { reference, resolveCommit, downloadArchive, extractArchive } from './download.mjs';
import { evaluate, interpolate, truthy, string } from './expression.mjs';
import { LogCommands, parseFileCommands, validEnvName, maskText } from './commands.mjs';
import { encodeState, decodeState } from './state.mjs';

const limit = 1048576;
const own = (object, key) => Object.hasOwn(object, key);
const mapping = (value, label) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be a mapping`);
  return value;
};
const scalarMap = (value, label) => Object.fromEntries(Object.entries(value ? mapping(value, label) : {}).map(([key, item]) => {
  if (item !== null && !['string', 'number', 'boolean'].includes(typeof item)) throw new Error(`${label}.${key} must be a scalar`);
  return [key, string(item)];
}));
export async function readBounded(filename, maximum = limit) {
  const handle = await fs.open(filename, 'r');
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > maximum) throw new Error('Action runtime file exceeds limits');
    const buffer = Buffer.alloc(maximum + 1);
    let size = 0;
    while (size < buffer.length) { const read = await handle.read(buffer, size, buffer.length - size, null); if (!read.bytesRead) break; size += read.bytesRead; }
    if (size > maximum) throw new Error('Action runtime file exceeds limits');
    return buffer.subarray(0, size).toString('utf8');
  } finally { await handle.close(); }
}
async function contained(root, relative) {
  if (typeof relative !== 'string' || !relative || path.isAbsolute(relative) || relative.includes('\\') || relative.split('/').includes('..')) throw new Error('Action path escapes its directory');
  const base = await fs.realpath(root), resolved = await fs.realpath(path.resolve(base, relative));
  if (resolved !== base && !resolved.startsWith(base + path.sep)) throw new Error('Action path escapes its directory');
  return resolved;
}
export async function metadata(directory) {
  let filename;
  for (const name of ['action.yml', 'action.yaml']) {
    try { filename = await contained(directory, name); break; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  if (!filename) throw new Error('Action has no action.yml or action.yaml');
  const source = await readBounded(filename, 65536);
  const document = parseDocument(source, { uniqueKeys: true, maxAliasCount: 0, customTags: [], strict: true });
  if (document.errors.length) throw new Error('Invalid action metadata YAML');
  // Reject anchors/aliases before conversion, bounding depth and node count.
  let count = 0;
  const walk = (node, depth = 0) => {
    if (++count > 8192 || depth > 32) throw new Error('Action metadata exceeds YAML limits');
    if (!node || typeof node !== 'object') return;
    if (node.anchor || node.source && node.constructor?.name === 'Alias') throw new Error('Action metadata aliases are unsupported');
    if (node.items) for (const item of node.items) walk(item, depth + 1);
    if (node.key) walk(node.key, depth + 1);
    if (node.value && typeof node.value === 'object') walk(node.value, depth + 1);
  };
  walk(document.contents);
  const value = mapping(document.toJS({ maxAliasCount: 0 }), 'action');
  const runs = mapping(value.runs, 'action.runs');
  if (!['node20', 'node24', 'composite'].includes(runs.using)) throw new Error(`Unsupported action runtime: ${runs.using}; supported: node20, node24, composite`);
  const allowed = runs.using === 'composite' ? ['using', 'steps'] : ['using', 'main', 'pre', 'pre-if', 'post', 'post-if'];
  for (const field of Object.keys(runs)) if (!allowed.includes(field)) throw new Error(`Unsupported action.runs.${field}`);
  if (runs.using === 'composite') {
    if (!Array.isArray(runs.steps) || !runs.steps.length || runs.steps.length > 64) throw new Error('Composite action requires 1 to 64 steps');
  } else if (typeof runs.main !== 'string') throw new Error('JavaScript action requires runs.main');
  const inputNames = new Set();
  for (const [name, input] of Object.entries(value.inputs || {})) {
    if (!/^[A-Za-z0-9_-]{1,100}$/.test(name)) throw new Error('Invalid action input name');
    if (inputNames.has(name.toLowerCase())) throw new Error('Duplicate action input name');
    inputNames.add(name.toLowerCase());
    mapping(input, 'input');
  }
  return value;
}
export class ActionRuntime {
  constructor(config, state = {}, adapters = {}) {
    this.config = config;
    this.state = Object.assign(state, { env: {}, path: [], steps: {}, posts: [], actions: {}, masks: [], ...state });
    this.adapters = { resolveCommit, downloadArchive, ...adapters };
    this.baseEnv = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith("MOONHUB_ACTION_")));
    this.workspace = path.resolve(config.workspace);
    this.temp = path.resolve(config.temp);
    this.failure = Boolean(config.failure || state.failure);
    this.cancelled = Boolean(config.cancelled);
    this.count = 0;
  }
  context(extra = {}) {
    const github = { repository: this.config.repository, sha: this.config.sha, server_url: this.config.server,
      api_url: `${this.config.server}/-/api/v1`, ref: this.config.context?.ref || this.config.sha,
      workflow: this.config.context?.workflow || '', run_id: this.config.run_id || '0', job: this.config.job_id || '',
      event_name: this.config.context?.event_name || 'workflow_dispatch', token: 'moonhub-local-source',
      workspace: this.workspace, head_ref: this.config.context?.head_ref || '', base_ref: this.config.context?.base_ref || '', ...extra.github };
    return { github, env: { ...this.baseEnv, ...this.state.env }, runner: { os: 'Linux', arch: process.arch === 'arm64' ? 'ARM64' : 'X64', temp: this.temp, tool_cache: path.join(this.baseEnv.HOME, '.tool-cache') },
      steps: this.state.steps, failure: this.failure, cancelled: this.cancelled, ...extra };
  }
  async resolve(uses) {
    if (uses.startsWith('./')) return { directory: await contained(this.workspace, uses), repository: this.config.repository, ref: this.config.sha };
    const requested = reference(uses);
    const key = createHash('sha256').update(requested.repository + '@' + requested.ref).digest('hex');
    let action = this.state.actions[key];
    if (!action) {
      const gitEnv = { PATH: this.baseEnv.PATH, HOME: this.baseEnv.HOME, GIT_TERMINAL_PROMPT: '0', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' };
      const commit = await this.adapters.resolveCommit(requested.repository, requested.ref, gitEnv);
      const directory = path.join(this.temp, '_actions', key);
      await extractArchive(await this.adapters.downloadArchive(requested.repository, commit), directory);
      action = { directory, repository: requested.repository, ref: requested.ref, commit };
      this.state.actions[key] = action;
      process.stdout.write(`Resolved ${requested.repository}@${requested.ref} to ${commit}\n`);
    }
    return { ...action, directory: requested.path ? await contained(action.directory, requested.path) : action.directory };
  }
  async process(program, args, env, cwd, result) {
    const stdout = new LogCommands(this.state, text => process.stdout.write(text), result);
    const stderr = new LogCommands(this.state, text => process.stderr.write(text), result);
    const child = spawn(program, args, { env, cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    const closed = new Promise(resolve => child.once('close', resolve));
    let streamError;
    const write = (sink, chunk) => { try { sink.write(chunk); } catch (error) { streamError = error; child.kill('SIGKILL'); } };
    child.stdout.on('data', chunk => write(stdout, chunk)); child.stderr.on('data', chunk => write(stderr, chunk));
    const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (code, signal) => resolve(signal ? 1 : code)); });
    // Match the native executor's bounded drain even for a detached pipe holder.
    let timer;
    await Promise.race([closed, new Promise(resolve => { timer = setTimeout(resolve, 250); })]);
    clearTimeout(timer);
    child.stdout.destroy(); child.stderr.destroy();
    stdout.end(); stderr.end();
    if (streamError) throw streamError;
    return code === 0 && !result.failed ? 0 : code || 1;
  }
  async files(env, result, execute) {
    const directory = path.join(this.temp, '_commands', randomUUID());
    await fs.mkdir(directory, { recursive: true, mode: 0o700 });
    const names = ['ENV', 'PATH', 'OUTPUT', 'STATE', 'STEP_SUMMARY'];
    const files = Object.fromEntries(names.map(name => [name, path.join(directory, name)]));
    for (const [name, filename] of Object.entries(files)) { await fs.writeFile(filename, '', { flag: 'wx', mode: 0o600 }); env[`GITHUB_${name}`] = filename; }
    try {
      const code = await execute();
      const changes = parseFileCommands(await readBounded(files.ENV));
      for (const key of Object.keys(changes)) if (!validEnvName(key)) throw new Error(`Reserved or unsafe action environment variable: ${key}`);
      this.state.env = { ...this.state.env, ...changes };
      const paths = (await readBounded(files.PATH)).replaceAll('\r\n', '\n').split('\n').filter(Boolean);
      if (paths.some(item => !path.isAbsolute(item) || /[\x00-\x1f\x7f:]/.test(item))) throw new Error('Invalid GITHUB_PATH entry');
      this.state.path = [...new Set([...paths.reverse(), ...this.state.path])];
      if (this.state.path.length > 300) throw new Error('Too many action PATH entries');
      result.outputs = { ...result.outputs, ...parseFileCommands(await readBounded(files.OUTPUT)) };
      result.state = { ...result.state, ...parseFileCommands(await readBounded(files.STATE)) };
      // Summaries remain a bounded local artifact until the server exposes them.
      const summary = await readBounded(files.STEP_SUMMARY);
      if (summary && ((await fs.stat(path.join(this.temp, "summary.md")).catch(() => ({size: 0}))).size + Buffer.byteLength(summary) > limit)) throw new Error("Action summaries exceed 1 MiB");
      if (summary) await fs.appendFile(path.join(this.temp, 'summary.md'), summary, { mode: 0o600 });
      return code;
    } finally { await fs.rm(directory, { recursive: true, force: true }); }
  }
  environment(extra = {}, context = this.context()) {
    const env = { ...this.baseEnv, ...this.state.env, ...extra };
    env.PATH = [...this.state.path, env.PATH].filter(Boolean).join(':');
    Object.assign(env, { GITHUB_WORKSPACE: this.workspace, GITHUB_REPOSITORY: this.config.repository, GITHUB_SHA: this.config.sha,
      GITHUB_SERVER_URL: this.config.server, GITHUB_API_URL: `${this.config.server}/-/api/v1`, GITHUB_EVENT_NAME: context.github.event_name,
      GITHUB_REF: context.github.ref, GITHUB_HEAD_REF: context.github.head_ref, GITHUB_BASE_REF: context.github.base_ref,
      GITHUB_ACTIONS: 'true', GITHUB_ACTION: this.config.step?.id || 'post',
      GITHUB_RUN_ID: this.config.run_id || '0', GITHUB_RUN_ATTEMPT: '1', GITHUB_JOB: this.config.job_id || '',
      RUNNER_OS: context.runner.os, RUNNER_ARCH: context.runner.arch, RUNNER_TEMP: this.temp, RUNNER_TOOL_CACHE: context.runner.tool_cache });
    if (context.github.action_path) env.GITHUB_ACTION_PATH = context.github.action_path;
    // Source transport redirects this one repository to an immutable local Git
    // bundle. No runner, provider, application or GitHub credential is exposed.
    if (this.config.source_git) {
      env.GIT_CONFIG_COUNT = '2'; env.GIT_CONFIG_KEY_0 = `url.${pathToFileURL(this.config.source_git).href}.insteadOf`;
      env.GIT_CONFIG_VALUE_0 = `${this.config.server}/${this.config.repository}`;
      env.GIT_CONFIG_KEY_1 = 'protocol.file.allow'; env.GIT_CONFIG_VALUE_1 = 'always';
    }
    return env;
  }
  async javascript(action, value, inputs, supplied, context, saved, phase) {
    const result = { outputs: {}, state: {}, failed: false };
    const inputEnv = Object.fromEntries(Object.entries(inputs).map(([name, value]) => [`INPUT_${name.toUpperCase()}`, value]));
    const stateEnv = Object.fromEntries(Object.entries(saved || {}).map(([name, value]) => [`STATE_${name}`, value]));
    const env = this.environment({ ...supplied, ...inputEnv, ...stateEnv, GITHUB_ACTION_PATH: action.directory,
      GITHUB_ACTION_REPOSITORY: action.repository, GITHUB_ACTION_REF: action.ref }, context);
    const node = value.runs.using === 'node20' ? this.config.node20 || '/opt/actions/node20/bin/node' : this.config.node24 || process.execPath;
    const filename = await contained(action.directory, value.runs[phase]);
    if (!(await fs.stat(filename)).isFile()) throw new Error('Action JavaScript entry is not a file');
    const code = await this.files(env, result, () => this.process(node, [filename], env, this.workspace, result));
    return { ...result, code };
  }
  async action(uses, provided = {}, supplied = {}, extra = {}, depth = 0) {
    if (depth > 8 || ++this.count > 256) throw new Error('Action nesting or invocation count exceeds limits');
    const action = await this.resolve(uses), value = await metadata(action.directory);
    const context = this.context({ ...extra, env: { ...this.context().env, ...extra.env, ...supplied }, github: { ...this.context().github, ...extra.github, action_path: action.directory } });
    const inputs = Object.create(null);
    for (const [name, definition] of Object.entries(value.inputs || {})) inputs[name.toLowerCase()] = interpolate(definition.default ?? '', context);
    for (const [name, item] of Object.entries(provided)) {
      if (!/^[A-Za-z0-9_-]{1,100}$/.test(name)) throw new Error('Invalid action input name');
      inputs[name.toLowerCase()] = string(item);
    }
    const inputContext = { ...context, inputs };
    if (value.runs.using === 'composite') {
      const steps = Object.create(null), outputs = Object.create(null);
      let compositeFailure = false;
      for (const [index, step] of value.runs.steps.entries()) {
        const ctx = { ...inputContext, failure: compositeFailure, cancelled: this.cancelled, steps, env: { ...this.context().env, ...supplied } };
        const id = step.id || `step_${index + 1}`;
        if (own(steps, id)) throw new Error('Duplicate composite step id');
        let result, tolerate = false;
        try {
          const condition = step.if === undefined ? !compositeFailure : truthy(evaluate(string(step.if), ctx, true));
          if (!condition) { steps[id] = { outputs: {}, outcome: 'skipped', conclusion: 'skipped' }; continue; }
          const allowed = ['id', 'name', 'if', 'run', 'shell', 'working-directory', 'env', 'uses', 'with', 'continue-on-error'];
          for (const field of Object.keys(step)) if (!allowed.includes(field)) throw new Error(`Unsupported composite step.${field}`);
          const env = { ...supplied };
          for (const [name, item] of Object.entries(scalarMap(step.env, 'step.env'))) {
            if (!validEnvName(name)) throw new Error('Invalid composite environment variable');
            env[name] = interpolate(item, ctx);
          }
          const stepContext = { ...ctx, env: { ...ctx.env, ...env } };
          tolerate = step['continue-on-error'] === undefined ? false : truthy(evaluate(string(step['continue-on-error']), stepContext));
          if (typeof step.uses === 'string' && step.run === undefined) {
            const with_ = Object.fromEntries(Object.entries(scalarMap(step.with, 'step.with')).map(([key, item]) => [key, interpolate(item, stepContext)]));
            result = await this.action(step.uses, with_, env, stepContext, depth + 1);
          } else if (typeof step.run === 'string' && step.uses === undefined && ['bash', 'sh'].includes(step.shell)) {
            result = await this.script(interpolate(step.run, stepContext), step.shell, interpolate(step['working-directory'] || '.', stepContext), env, stepContext);
          } else throw new Error('Composite steps require run with bash/sh or uses');
        } catch (error) {
          this.error(error);
          result = { code: 1, outputs: {} };
        }
        const failed = result.code !== 0;
        steps[id] = { outputs: result.outputs, outcome: failed ? 'failure' : 'success', conclusion: failed && !tolerate ? 'failure' : 'success' };
        if (failed && !tolerate) compositeFailure = true;
      }
      for (const [name, output] of Object.entries(value.outputs || {})) outputs[name] = interpolate(output.value || '', { ...inputContext, steps });
      return { code: compositeFailure ? 1 : 0, outputs, state: {} };
    }
    // Pre and main share private action state; post handlers run once, LIFO.
    let saved = {};
    let post;
    if (value.runs.post) {
      post = { action, value, inputs, env: supplied, saved, condition: value.runs['post-if'] || 'always()' };
      this.state.posts.push(post);
    }
    if (value.runs.pre && truthy(evaluate(value.runs['pre-if'] || 'always()', context))) {
      const pre = await this.javascript(action, value, inputs, supplied, context, saved, 'pre'); saved = pre.state;
      if (post) post.saved = saved;
      if (pre.code) return pre;
    }
    const main = await this.javascript(action, value, inputs, supplied, context, saved, 'main');
    if (post) post.saved = { ...saved, ...main.state };
    return main;
  }
  async script(run, shell = '', directory = '.', supplied = {}, context = this.context()) {
    const cwd = await contained(this.workspace, directory);
    const filename = path.join(this.temp, `script-${randomUUID()}.sh`);
    await fs.writeFile(filename, run, { flag: 'wx', mode: 0o600 });
    const env = this.environment(supplied, context), result = { outputs: {}, state: {}, failed: false };
    const program = shell === 'sh' ? '/bin/sh' : '/bin/bash';
    const args = shell === 'sh' ? ['-e', filename] : ['--noprofile', '--norc', '-e', ...(shell === 'bash' ? ['-o', 'pipefail'] : []), filename];
    try { const code = await this.files(env, result, () => this.process(program, args, env, cwd, result)); return { ...result, code }; }
    finally { await fs.rm(filename, { force: true }); }
  }
  error(error) {
    const raw = error instanceof Error ? error.message : 'Action execution failed';
    // Mask before sanitizing so multiline secrets cannot become unmasked fragments.
    const message = Buffer.byteLength(raw) > limit ? 'Action error exceeds limits' :
      maskText(raw, this.state.masks).replace(/[\x00-\x1f\x7f]/g, ' ').slice(0, 4096);
    process.stderr.write(`runner: ${message}\n`);
  }
  async posts() {
    let code = 0;
    while (this.state.posts.length) {
      const post = this.state.posts.pop(), context = this.context();
      try {
        if (!truthy(evaluate(post.condition, context))) continue;
        const result = await this.javascript(post.action, post.value, post.inputs, post.env, context, post.saved, 'post');
        if (result.code) { code = result.code; this.failure = true; this.state.failure = true; }
      } catch { process.stderr.write('runner: action post failed\n'); code = 1; this.failure = true; this.state.failure = true; }
    }
    return code;
  }
}

export async function execute(config, state = {}, adapters = {}) {
  const runtime = new ActionRuntime(config, state, adapters);
  await fs.mkdir(runtime.temp, { recursive: true, mode: 0o700 });
  if (config.phase === 'post') return { code: await runtime.posts(), state: runtime.state };
  const previousFailure = runtime.failure;
  const step = config.step, templates = step.templates || {};
  let result, tolerate = false;
  try {
    const overrides = new Set(step.env_overrides ?? Object.keys(step.env || {}));
    const inheritedExport = key => own(runtime.state.env, key) && !overrides.has(key);
    const supplied = Object.fromEntries(Object.entries(step.env || {}).filter(([key]) => !inheritedExport(key)));
    const condition = templates.if ?? 'success()';
    if (!truthy(evaluate(condition, runtime.context({ env: { ...runtime.context().env, ...supplied } }), true))) {
      runtime.state.steps[step.id] = { outputs: {}, outcome: 'skipped', conclusion: 'skipped' };
      return { code: 0, conclusion: 'skipped', state: runtime.state };
    }
    for (const key of Object.keys(step.secret_env || {})) {
      if (!own(process.env, key)) throw new Error('Action secret was not delivered');
      const input = step.remote && Object.keys(step.inputs || {}).some(name => `INPUT_${name.toUpperCase()}` === key);
      if (input || !inheritedExport(key)) supplied[key] = process.env[key];
      if (process.env[key] && !runtime.state.masks.includes(process.env[key])) runtime.state.masks.push(process.env[key]);
    }
    const envContext = runtime.context({ env: { ...runtime.context().env, ...supplied } });
    for (const [key, template] of Object.entries(templates)) if (key.startsWith('env:') && !inheritedExport(key.slice(4))) supplied[key.slice(4)] = interpolate(template, envContext);
    const context = runtime.context({ env: { ...runtime.context().env, ...supplied } });
    const inputs = { ...step.inputs };
    for (const [key, template] of Object.entries(templates)) if (key.startsWith('with:')) inputs[key.slice(5)] = interpolate(template, context);
    for (const name of Object.keys(inputs)) {
      const key = `INPUT_${name.toUpperCase()}`;
      if (own(step.secret_env || {}, key)) inputs[name] = supplied[key];
    }
    tolerate = templates['continue-on-error'] === undefined ? false : truthy(evaluate(templates['continue-on-error'], context));
    result = step.remote ? await runtime.action(step.uses, inputs, supplied) :
      await runtime.script(templates.run === undefined ? step.run : interpolate(templates.run, context), step.shell, step.working_directory, supplied);
  } catch (error) {
    runtime.error(error);
    result = { code: 1, outputs: {} };
  }
  const outcome = result.code ? 'failure' : 'success', conclusion = result.code && !tolerate ? 'failure' : 'success';
  runtime.state.steps[step.id] = { outputs: result.outputs, outcome, conclusion };
  runtime.state.failure = previousFailure || conclusion === 'failure';
  return { code: conclusion === 'failure' ? result.code : 0, conclusion, state: runtime.state };
}

async function main() {
  const filename = process.argv[2], stateFile = process.argv[3];
  if (!filename || !stateFile) throw new Error('Action runtime requires a plan and state path');
  const config = JSON.parse(await readBounded(filename));
  const key = process.env.MOONHUB_ACTION_STATE_KEY;
  delete process.env.MOONHUB_ACTION_STATE_KEY;
  let state = {};
  try { state = decodeState(await readBounded(stateFile, 6000000), key); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const runtime = new ActionRuntime(config, state);
  let result;
  try {
    // Keep runtime state even when main fails, so registered cleanup runs.
    result = await execute(config, runtime.state);
  } catch (error) {
    process.stderr.write("runner: action runtime evaluation failed\n");
    runtime.state.failure = true;
    result = { code: 1, state: runtime.state };
  }
  await fs.writeFile(stateFile, encodeState(result.state, key), { mode: 0o600 });
  if (config.result_file) await fs.writeFile(config.result_file, JSON.stringify({ conclusion: result.conclusion || 'failure' }), { mode: 0o600 });
  process.exitCode = result.code;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => { process.stderr.write('runner: action runtime failed\n'); process.exitCode = 1; });
}
