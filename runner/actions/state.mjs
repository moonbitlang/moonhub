import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
function keyBytes(key) {
  if (!/^[a-f0-9]{64}$/.test(key || '')) throw new Error('Action state key is unavailable');
  return Buffer.from(key, 'hex');
}
export function encodeState(state, key) {
  const json = JSON.stringify(state);
  if (Buffer.byteLength(json) > 4194304) throw new Error('Action runtime state exceeds 4 MiB');
  const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', keyBytes(key), iv);
  const encrypted = Buffer.concat([cipher.update(json, 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), encrypted]).toString('base64');
}
export function decodeState(text, key) {
  const buffer = Buffer.from(text, 'base64');
  if (buffer.length < 28 || buffer.length > 4194332) throw new Error('Invalid action state');
  const cipher = createDecipheriv('aes-256-gcm', keyBytes(key), buffer.subarray(0, 12));
  cipher.setAuthTag(buffer.subarray(12, 28));
  return JSON.parse(Buffer.concat([cipher.update(buffer.subarray(28)), cipher.final()]).toString('utf8'));
}
