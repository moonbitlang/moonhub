import { StringDecoder } from 'node:string_decoder';
export function parseFileCommands(text) {
  if (Buffer.byteLength(text) > 1048576 || text.includes('\0')) throw new Error('Action file command exceeds limits');
  const lines = text.replaceAll('\r\n', '\n').split('\n'), result = Object.create(null);
  for (let index = 0; index < lines.length;) {
    const line = lines[index++];
    if (!line) continue;
    const equal = line.indexOf('='), delimiter = line.indexOf('<<');
    if (delimiter > 0 && (equal < 0 || delimiter < equal)) {
      const name = line.slice(0, delimiter), end = line.slice(delimiter + 2), values = [];
      if (!end) throw new Error('Invalid file command delimiter');
      while (index < lines.length && lines[index] !== end) values.push(lines[index++]);
      if (index === lines.length) throw new Error('Unterminated file command');
      result[name] = values.join('\n'); index++;
    } else if (equal > 0) result[line.slice(0, equal)] = line.slice(equal + 1);
    else throw new Error('Invalid file command');
    if (Object.keys(result).length > 300) throw new Error('Too many file commands');
  }
  return result;
}
export function validEnvName(name) {
  return /^[A-Za-z_][A-Za-z0-9_]{0,99}$/.test(name) && !/^(GITHUB_|RUNNER_|MOONHUB_|LD_|DYLD_)/i.test(name) &&
    !['BASH_ENV', 'ENV', 'SHELLOPTS', 'BASHOPTS', 'NODE_OPTIONS'].includes(name.toUpperCase());
}
const unescape = value => value.replaceAll('%0D', '\r').replaceAll('%0A', '\n').replaceAll('%25', '%');
// Process commands before publishing any log bytes. Chunk boundaries (including
// split UTF-8, masks and command prefixes) must not expose masked values.
export class LogCommands {
  constructor(state, output, result) { this.state = state; this.output = output; this.result = result; this.pending = ''; this.decoder = new StringDecoder('utf8'); this.stop = ''; }
  write(chunk) {
    this.pending += this.decoder.write(chunk);
    let end;
    while ((end = this.pending.indexOf('\n')) >= 0) { this.line(this.pending.slice(0, end)); this.pending = this.pending.slice(end + 1); }
    if (Buffer.byteLength(this.pending) > 1048576) throw new Error('Action log line exceeds 1 MiB');
  }
  end() { this.pending += this.decoder.end(); if (this.pending) this.line(this.pending, false); this.pending = ''; }
  line(line, terminated = true) {
    if (Buffer.byteLength(line) > 1048576) throw new Error('Action log line exceeds 1 MiB');
    const text = line.replace(/\r$/, '');
    if (this.stop) { if (text === `::${this.stop}::`) { this.stop = ''; return; } }
    else {
      const command = /^::([\w-]+)(?: ([^:]*))?::(.*)$/.exec(text);
      if (command) {
        const [, name, properties = '', raw] = command, value = unescape(raw);
        const props = Object.fromEntries(properties.split(',').filter(Boolean).map(part => { const i = part.indexOf('='); return [part.slice(0, i), unescape(part.slice(i + 1)).replaceAll('%3A', ':').replaceAll('%2C', ',')]; }));
        if (name === 'add-mask') {
          for (const mask of [value, ...value.split(/\s+/)]) if (mask && !this.state.masks.includes(mask)) this.state.masks.push(mask);
          if (this.state.masks.length > 1024) throw new Error('Too many action masks');
          return;
        }
        if (['debug', 'add-matcher', 'remove-matcher'].includes(name)) return;
        if (name === 'stop-commands') { this.stop = value; return; }
        if (name === 'set-output') { if (props.name) this.result.outputs[props.name] = value; return; }
        if (name === 'save-state') { if (props.name) this.result.state[props.name] = value; return; }
        if (['set-env', 'add-path'].includes(name)) throw new Error('Deprecated unsafe workflow command; use environment files');
      }
    }
    this.output(maskText(line, this.state.masks) + (terminated ? '\n' : ''));
  }
}

export function maskText(text, masks) {
  let masked = text;
  // Union overlapping occurrences so partially overlapping masks cannot leak.
  const spans = [];
  for (const mask of masks) if (mask) for (let i = masked.indexOf(mask); i >= 0; i = masked.indexOf(mask, i + 1)) spans.push([i, i + mask.length]);
  spans.sort((a, b) => a[0] - b[0]);
  const merged = [];
  for (const span of spans) { const last = merged.at(-1); if (last && span[0] <= last[1]) last[1] = Math.max(last[1], span[1]); else merged.push(span); }
  for (const [start, end] of merged.reverse()) masked = masked.slice(0, start) + '***' + masked.slice(end);
  return masked;
}
