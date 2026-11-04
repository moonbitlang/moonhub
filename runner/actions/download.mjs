import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createGunzip } from 'node:zlib';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
const exec = promisify(execFile);
export function reference(value) {
  const match = /^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)((?:\/[A-Za-z0-9_.-]+)*)@([A-Za-z0-9_+./-]+)$/.exec(value);
  if (!match || value.length > 1024) throw new Error('Invalid GitHub Action reference');
  const [, owner, repo, subpath, ref] = match;
  if ([owner, repo].some(v => v.startsWith('-') || ['.', '..', '.git'].includes(v)) ||
      subpath.split('/').slice(1).some(v => ['.', '..', '.git'].includes(v)) || ref.length > 200 ||
      ref.includes('..') || ref.endsWith('.') || ref.endsWith('.lock') || ref.startsWith('-') ||
      ref.split('/').some(v => !v || v.startsWith('.'))) throw new Error('Invalid GitHub Action reference');
  return { repository: `${owner}/${repo}`, path: subpath.slice(1), ref };
}
export async function resolveCommit(repository, ref, env, execute = exec) {
  if (/^[a-fA-F0-9]{40}$/.test(ref)) return ref.toLowerCase();
  const names = ref.startsWith('refs/') ? [ref, `${ref}^{}`] : [`refs/tags/${ref}`, `refs/tags/${ref}^{}`, `refs/heads/${ref}`];
  const { stdout } = await execute('git', ['-c', 'credential.helper=', 'ls-remote', '--exit-code',
    `https://github.com/${repository}.git`, ...names],
    { env, timeout: 30000, maxBuffer: 1048576 });
  const refs = new Map(stdout.trim().split('\n').map(line => { const [sha, name] = line.split('	'); return [name, sha]; }));
  const sha = ref.startsWith('refs/') ? refs.get(`${ref}^{}`) || refs.get(ref) :
    refs.get(`refs/tags/${ref}^{}`) || refs.get(`refs/tags/${ref}`) || refs.get(`refs/heads/${ref}`);
  if (!/^[a-f0-9]{40}$/.test(sha)) throw new Error('Action ref does not resolve to a commit');
  return sha;
}
export async function downloadArchive(repository, sha) {
  const response = await fetch(`https://codeload.github.com/${repository}/tar.gz/${sha}`, { signal: AbortSignal.timeout(30000), redirect: 'error' });
  if (!response.ok) throw new Error(`Action archive download failed (${response.status})`);
  const chunks = []; let compressed = 0, total = 0;
  const limited = async function* () {
    for await (const chunk of response.body) {
      compressed += chunk.length; if (compressed > 67108864) throw new Error('Action archive exceeds 64 MiB'); yield chunk;
    }
  };
  await pipeline(Readable.from(limited()), createGunzip(), async function* (source) {
    for await (const chunk of source) {
      total += chunk.length;
      if (total > 268435456) throw new Error('Expanded action archive exceeds 256 MiB');
      chunks.push(chunk);
    }
  });
  return Buffer.concat(chunks);
}
function tarString(buffer) { return buffer.subarray(0, buffer.indexOf(0) < 0 ? buffer.length : buffer.indexOf(0)).toString('utf8'); }
function paxFields(buffer) {
  const fields = Object.create(null); let cursor = 0;
  while (cursor < buffer.length) {
    const space = buffer.indexOf(32, cursor), length = Number(buffer.subarray(cursor, space).toString());
    if (space < cursor || !Number.isInteger(length) || length < space - cursor + 3 || cursor + length > buffer.length) throw new Error('Malformed tar extended header');
    const record = buffer.subarray(space + 1, cursor + length - 1).toString('utf8'), equal = record.indexOf('=');
    if (equal > 0) fields[record.slice(0, equal)] = record.slice(equal + 1);
    cursor += length;
  }
  return fields;
}
export async function extractArchive(buffer, directory) {
  let offset = 0, count = 0, root = '', attributes = {};
  const entries = [], names = new Set();
  while (offset + 512 <= buffer.length) {
    const header = buffer.subarray(offset, offset + 512); offset += 512;
    if (header.every(byte => byte === 0)) break;
    const recorded = Number.parseInt(tarString(header.subarray(148, 156)).trim(), 8);
    const checksum = header.reduce((sum, value, i) => sum + (i >= 148 && i < 156 ? 32 : value), 0);
    const sizeText = tarString(header.subarray(124, 136)).trim();
    if (recorded !== checksum || !/^[0-7]+$/.test(sizeText)) throw new Error('Malformed action tar header');
    const size = Number.parseInt(sizeText, 8), type = tarString(header.subarray(156, 157));
    if (size > 67108864 || offset + size > buffer.length) throw new Error('Action file exceeds archive bounds');
    const content = buffer.subarray(offset, offset + size); offset += Math.ceil(size / 512) * 512;
    if (type === 'x') { attributes = paxFields(content); continue; }
    if (type === 'g') { const global = paxFields(content); if (Object.keys(global).some(key => !['comment', 'mtime', 'atime', 'ctime'].includes(key))) throw new Error('Unsupported global tar metadata'); continue; }
    const prefix = tarString(header.subarray(257, 263)) === 'ustar' ? tarString(header.subarray(345, 500)) : '';
    let name = attributes.path || [prefix, tarString(header.subarray(0, 100))].filter(Boolean).join('/');
    attributes = {};
    name = name.replace(/\/$/, '');
    const parts = name.split('/');
    if (!name || parts.some(part => !part || ['.', '..', '.git'].includes(part) || /[\x00-\x1f\x7f\\:]/.test(part)) || name.length > 1024) throw new Error('Unsafe action archive path');
    if (!root) root = parts[0];
    if (root !== parts[0]) throw new Error('Action archive has multiple roots');
    if (!['', '0', '5'].includes(type)) throw new Error('Action archives may contain only regular files and directories');
    if (parts.length === 1) continue;
    const relative = parts.slice(1).join('/');
    if (names.has(relative) || ++count > 10000) throw new Error('Action archive contains duplicate paths or too many files');
    names.add(relative);
    const executable = Number.parseInt(tarString(header.subarray(100, 108)).trim(), 8) & 0o111;
    entries.push({ relative, type, content, executable });
  }
  if (!root || !entries.length) throw new Error('Action archive is empty');
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  for (const entry of entries) {
    const filename = path.join(directory, entry.relative);
    if (entry.type === '5') await fs.mkdir(filename, { recursive: true, mode: 0o700 });
    else { await fs.mkdir(path.dirname(filename), { recursive: true, mode: 0o700 }); await fs.writeFile(filename, entry.content, { flag: 'wx', mode: entry.executable ? 0o700 : 0o600 }); }
  }
}
