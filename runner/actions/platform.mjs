import path from 'node:path';
export const windows = process.platform === 'win32';
export const runnerOS = windows ? 'Windows' : process.platform === 'darwin' ? 'macOS' : 'Linux';
export const nullDevice = windows ? 'NUL' : '/dev/null';
export function validRelative(value) {
  if (typeof value !== 'string' || !value || path.isAbsolute(value) || /[\\:\x00-\x1f\x7f]/.test(value)) return false;
  return value.split('/').every(part => part && part !== '..' && (!windows || part === '.' ||
    (!/[. ]$/.test(part) && !/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part))));
}
export function isWithin(root, filename) {
  const relative = path.relative(root, filename);
  return !path.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + path.sep);
}
// Windows environment keys are case-insensitive. Fold before merging so an
// exported `Path` cannot shadow the explicit step's `PATH` (or vice versa).
export function environment(...layers) {
  const result = Object.create(null);
  for (const layer of layers) for (const [name, value] of Object.entries(layer || {}))
    result[windows ? name.toUpperCase() : name] = value;
  return result;
}
export function shellCommand(shell, filename) {
  shell ||= windows ? 'pwsh' : 'bash-default';
  if (shell === 'pwsh') return [windows ? 'pwsh.exe' : 'pwsh', ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', filename]];
  if (shell === 'sh') return [windows ? 'sh.exe' : '/bin/sh', ['-e', filename]];
  if (shell === 'bash' || shell === 'bash-default') return [windows ? 'bash.exe' : '/bin/bash', ['--noprofile', '--norc', '-e', ...(shell === 'bash' ? ['-o', 'pipefail'] : []), filename]];
  throw new Error(`Unsupported shell: ${shell}`);
}
export function scriptSource(run, shell) {
  return shell === 'pwsh' || (!shell && windows)
    ? `$ErrorActionPreference = 'Stop'\n$ProgressPreference = 'SilentlyContinue'\n${run}\nif (Test-Path variable:LASTEXITCODE) { exit $LASTEXITCODE }\n` : run;
}
