import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import { readArchive, reference } from './download.mjs';
import { nullDevice } from './platform.mjs';
const exec = promisify(execFile);

export function gitSetting(env, name, value) {
  const index = Number(env.GIT_CONFIG_COUNT || 0);
  if (!Number.isInteger(index) || index < 0 || index > 100) throw new Error('Invalid Git configuration');
  env[`GIT_CONFIG_KEY_${index}`] = name; env[`GIT_CONFIG_VALUE_${index}`] = value; env.GIT_CONFIG_COUNT = String(index + 1);
}
export class DependencyClient {
  constructor(config, token, url, fetcher = fetch) {
    if (!/^[a-f0-9]{64}$/.test(token) || url !== config.server + '/-/runner-api/v1/dependencies') throw new Error('Invalid dependency service credential');
    this.config = config; this.token = token; this.url = url; this.fetcher = fetcher;
  }
  async request(operation, repository, ref, full_history = false) {
    reference(`${repository}@${ref}`);
    const response = await this.fetcher(this.url + '/' + operation, { method: 'POST', headers: { Authorization: 'Bearer ' + this.token, 'Content-Type': 'application/json' }, body: JSON.stringify({ repository, ref, ...(operation === 'source' ? { full_history } : {}) }), redirect: 'error', signal: AbortSignal.timeout(70000) });
    if (!response.ok) throw new Error(`Dependency access failed (${response.status}); verify repository/ref grants, token lifetime and source limits`);
    return response;
  }
  async resolve(repository, ref) {
    const response = await this.request('resolve', repository, ref);
    const value = JSON.parse((await this.bytes(response, 4096)).toString());
    if (value.private === false) return null;
    if (value.private !== true || !/^[a-f0-9]{40}$/.test(value.sha)) throw new Error('Invalid private action resolution');
    return value.sha;
  }
  async archive(repository, ref) { return readArchive((await this.request('archive', repository, ref)).body); }
  async bytes(response, limit = 67108864) {
    const chunks = []; let size = 0;
    for await (const chunk of response.body) { size += chunk.length; if (size > limit) throw new Error('Dependency response exceeds limits'); chunks.push(chunk); }
    return Buffer.concat(chunks);
  }
  async source(repository, ref, fullHistory, env) {
    const response = await this.request('source', repository, ref, fullHistory);
    const sha = response.headers.get('x-moonhub-commit');
    if (!/^[a-f0-9]{40}$/.test(sha)) throw new Error('Invalid source commit');
    const directory = path.join(this.config.temp, '_sources', randomUUID());
    await fs.mkdir(directory, { recursive: true, mode: 0o700 });
    const bundle = path.join(directory, 'source.bundle'), git = path.join(directory, 'source.git');
    try {
      await fs.writeFile(bundle, await this.bytes(response), { mode: 0o600, flag: 'wx' });
      const options = { env: { PATH: env.PATH, HOME: env.HOME || env.USERPROFILE, SystemRoot: env.SYSTEMROOT, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: nullDevice, GIT_TERMINAL_PROMPT: '0' }, timeout: 30000, maxBuffer: 1048576 };
      await exec('git', ['-c', `core.hooksPath=${nullDevice}`, 'init', '--bare', '--quiet', git], options);
      const { stdout } = await exec('git', ['-c', `core.hooksPath=${nullDevice}`, '--git-dir', git, 'bundle', 'unbundle', bundle], options);
      const lines = stdout.trim().split(/\r?\n/);
      if (lines.length > 4097) throw new Error('Source tag limit exceeded');
      for (const line of lines) {
        const match = /^([a-f0-9]{40}) (refs\/heads\/moonhub-source|refs\/tags\/[^\s]+)$/.exec(line);
        if (!match) throw new Error('Invalid source bundle ref');
        reference(`source/repository@${match[2]}`);
        await exec('git', ['-c', `core.hooksPath=${nullDevice}`, '--git-dir', git, 'update-ref', match[2], match[1]], options);
      }
      await exec('git', ['--git-dir', git, 'cat-file', '-e', `${sha}^{commit}`], options);
      if (!fullHistory) await fs.writeFile(path.join(git, 'shallow'), sha + '\n', { mode: 0o600 });
      await fs.rm(bundle);
      return { sha, git, repository };
    } catch { await fs.rm(directory, { recursive: true, force: true }); throw new Error('Source bundle preparation failed; verify source limits and Git availability'); }
  }
}

export function sourceEnvironment(env, source, config) {
  // Replace the primary rewrite when expanding its history. Other repositories
  // get distinct URL prefixes and never inherit the primary checkout's scope.
  if (source.repository === config.repository && env.GIT_CONFIG_COUNT === '3') {
    env.GIT_CONFIG_KEY_0 = env.GIT_CONFIG_KEY_2 = `url.${pathToFileURL(source.git).href}.insteadOf`;
  } else {
    gitSetting(env, `url.${pathToFileURL(source.git).href}.insteadOf`, `${config.server}/${source.repository}`);
    gitSetting(env, `url.${pathToFileURL(source.git).href}.insteadOf`, `http://moonhub.localhost/${source.repository}`);
    gitSetting(env, 'protocol.file.allow', 'always');
  }
}
