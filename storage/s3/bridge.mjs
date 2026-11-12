import { createStore } from './backend.mjs';
import { once } from 'node:events';

const cancellation = new AbortController();
process.once('SIGTERM', () => cancellation.abort());
process.once('SIGINT', () => cancellation.abort());
const write = async data => { if (!process.stdout.write(data)) await once(process.stdout, 'drain'); };

async function main() {
  const input = process.stdin[Symbol.asyncIterator]();
  let header = Buffer.alloc(0), rest = Buffer.alloc(0);
  for (;;) {
    const { done, value } = await input.next();
    if (done) throw Error('InvalidRequest');
    const boundary = value.indexOf(10);
    const prefix = boundary < 0 ? value : value.subarray(0, boundary);
    if (header.length + prefix.length > 65536) throw Error('InvalidRequest');
    header = Buffer.concat([header, prefix]);
    if (boundary >= 0) { rest = value.subarray(boundary + 1); break; }
  }
  const request = JSON.parse(header.toString('utf8'));
  if (request.version !== 1 || !request.request || !request.location) throw Error('InvalidRequest');
  const store = createStore(request.location, { signal: cancellation.signal });
  try {
    const { operation, request: args } = request;
    let result = {};
    if (operation === 'verify') { result = { version: 1 }; }
    else if (operation === 'put') {
      if (!Number.isSafeInteger(args.size) || args.size < 1 || args.size > 128 * 1024 * 1024) throw Error('InvalidRequest');
      const bytes = Buffer.allocUnsafe(args.size);let offset = 0;
      const accept = chunk => {
        if (offset + chunk.length > bytes.length) throw Error('InvalidRequest');
        chunk.copy(bytes, offset); offset += chunk.length;
      };
      accept(rest);
      for (;;) { const next = await input.next();if (next.done) break;accept(next.value); }
      if (offset !== bytes.length) throw Error('InvalidRequest');
      await store.put(args.key, bytes);
    } else if (operation === 'compose') { result = await store.compose(args.key, args.parts); }
    else if (operation === 'remove') { await store.remove(args.key); }
    else if (operation === 'remove_namespace') { await store.removeNamespace(args.key); }
    else if (operation === 'read') {
      const body = await store.read(args.key, args.size);
      try {
        await write(JSON.stringify({ ok: true }) + '\n');
        for await (const chunk of body) await write(chunk);
      } finally { body.destroy(); }
      return;
    } else throw Error('InvalidOperation');
    await write(JSON.stringify(result));
  } finally { store.close(); }
}

main().catch(() => {
  // Do not disclose provider diagnostics, object names, signed URLs or credentials.
  process.stderr.write('S3 storage operation failed\n');
  process.exitCode = 1;
});
