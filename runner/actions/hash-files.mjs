import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { isWithin } from './platform.mjs';

// Pin the toolkit version in package.json: these matcher primitives implement
// Actions' escaping, implicit descendants and ordered exclusions. Keep our own
// traversal to reject out-of-workspace symlinks before descending or reading.
const toolkit = path.dirname(fileURLToPath(import.meta.resolve('@actions/glob')));
const { Pattern } = await import(pathToFileURL(path.join(toolkit, 'internal-pattern.js')));
const { getSearchPaths, match, partialMatch } = await import(pathToFileURL(path.join(toolkit, 'internal-pattern-helper.js')));

export async function hashFiles(workspace, args) {
  if (typeof workspace !== 'string' || !workspace || !args.length || args.length > 100 || args.some(x => typeof x !== 'string')) throw new Error('hashFiles requires a workspace and string patterns');
  const input = args.join('\n');
  if (Buffer.byteLength(input) > 65536 || input.includes('\0')) throw new Error('hashFiles patterns exceed limits');
  const root = await fs.realpath(workspace), patterns = [];
  for (let line of input.replaceAll('\r', '\n').split('\n')) {
    line = line.trim();
    if (!line || line.startsWith('#')) continue;
    let negate = false;
    while (line.startsWith('!')) { negate = !negate; line = line.slice(1).trim(); }
    if (!line) continue;
    const resolved = path.resolve(root, line);
    if (!isWithin(root, resolved)) continue;
    const absolute = path.isAbsolute(line) ? line : Pattern.globEscape(root) + resolved.slice(root.length) + (line.endsWith(path.sep) || line.endsWith('/') ? path.sep : '');
    const pattern = new Pattern((negate ? '!' : '') + absolute);
    // Outside patterns cannot affect the result and must never initiate a walk.
    if (!isWithin(root, pattern.searchPath)) continue;
    patterns.push(pattern);
    if (pattern.trailingSeparator || pattern.segments.at(-1) !== '**') patterns.push(new Pattern(pattern.negate, true, [...pattern.segments, '**']));
  }
  if (patterns.length > 200) throw new Error('hashFiles has too many patterns');
  const result = createHash('sha256');
  let entries = 0, files = 0, bytes = 0;
  async function walk(filename, ancestors = new Set()) {
    if (++entries > 100000) throw new Error('hashFiles entry limit exceeded');
    const matched = match(patterns, filename);
    if (!matched && !partialMatch(patterns, filename)) return;
    let resolved, stat;
    try { resolved = await fs.realpath(filename); if (!isWithin(root, resolved)) return; stat = await fs.stat(resolved); }
    catch (error) { if (['ENOENT', 'ELOOP', 'ENOTDIR'].includes(error.code)) return; throw error; }
    if (stat.isDirectory()) {
      if (ancestors.has(resolved)) return;
      const next = new Set(ancestors).add(resolved);
      // Match the toolkit's traversal order, including multiple search roots.
      for (const entry of await fs.readdir(resolved)) await walk(path.join(filename, entry), next);
      return;
    }
    if (!stat.isFile() || !(matched & 2)) return;
    if (++files > 10000) throw new Error('hashFiles file limit exceeded');
    const file = await fs.open(resolved, 'r');
    try {
      if (!(await file.stat()).isFile()) throw new Error('hashFiles requires regular files');
      const digest = createHash('sha256'), buffer = Buffer.alloc(65536);
      while (true) {
        const { bytesRead } = await file.read(buffer, 0, buffer.length, null);
        if (!bytesRead) break;
        bytes += bytesRead;
        if (bytes > 536870912) throw new Error('hashFiles byte limit exceeded');
        digest.update(buffer.subarray(0, bytesRead));
      }
      result.update(digest.digest());
    } finally { await file.close(); }
  }
  for (const start of getSearchPaths(patterns)) await walk(start);
  return files ? result.digest('hex') : '';
}
